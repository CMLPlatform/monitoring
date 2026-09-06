#!/usr/bin/env bash
# Emit OpenTofu `import` blocks for the Cloudflare resources that already exist.
#
# A first plan against an empty state says "create" for objects already serving
# traffic, and applying it mints a second tunnel and duplicate DNS records. Import
# blocks make the adoption reviewable: read the generated file, then the plan, then
# apply.
#
# The ingestion record was renamed from `otlp.<domain>` to `otel.<domain>` (2026-09).
# On a state that predates the rename, the live record is imported as
# `cloudflare_dns_record.otel`, so the apply renames it in place.
#
# The generated imports.tf is a throwaway: delete it after the apply, or every plan
# re-runs the imports.
#
# Usage (run in this directory, with terraform.tfvars already filled in):
#   export CLOUDFLARE_API_TOKEN=...        # Tunnel:Read, DNS:Read, Access: Apps and Policies:Read
#   ./generate-imports.sh > imports.tf
#   tofu plan                              # expect "0 to add", only in-place changes
#   tofu apply && rm imports.tf
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

die() {
    echo "error: $*" >&2
    exit 1
}

api() {
    # Token via curl config on stdin, not argv: /proc/<pid>/cmdline is world-readable.
    curl -fsS --config - "https://api.cloudflare.com/client/v4/$1" \
        <<<"header = \"Authorization: Bearer ${CLOUDFLARE_API_TOKEN}\""
}

command -v jq >/dev/null || die "jq is required"
: "${CLOUDFLARE_API_TOKEN:?is not set}"

# Read the ids from terraform.tfvars; an exported TF_VAR_* still wins.
[[ -f terraform.tfvars ]] || die "no terraform.tfvars here; copy terraform.tfvars.example and fill it in"
tfvar() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" terraform.tfvars | tail -1
}
account="${TF_VAR_account_id:-$(tfvar account_id)}"
zone="${TF_VAR_zone_id:-$(tfvar zone_id)}"
domain="${TF_VAR_domain:-$(tfvar domain)}"

# The example file's placeholders are valid-looking strings; catch them here.
for pair in "account_id:$account" "zone_id:$zone" "domain:$domain"; do
    value="${pair#*:}"
    [[ -n "$value" ]] || die "${pair%%:*} is empty in terraform.tfvars"
    case "$value" in
        your-* | example.org) die "${pair%%:*} is still the placeholder from terraform.tfvars.example" ;;
    esac
done

# A silently skipped import comes back as a "create" in the plan, so each lookup
# fails loudly when the resource is absent.
lookup_dns_record() {
    local hostname="$1" id
    # Type-filtered: an unfiltered .result[0] could bind a TXT record on the same
    # name, and the apply would rewrite it into a CNAME. Two statements, not one
    # pipeline: this runs inside `if`/`||`, where errexit is off, and a failed API
    # call must not be reported as "no record".
    local body
    body="$(api "zones/$zone/dns_records?name=$hostname&type=CNAME")" || die "DNS lookup for $hostname failed (token lacks DNS:Read?)"
    id="$(jq -r '.result[0].id // empty' <<<"$body")"
    [[ -n "$id" ]] || return 1
    printf '%s' "$id"
}

tunnel_name="${MONITORING_TUNNEL_NAME:-cml-monitoring}"
tunnels="$(api "accounts/$account/cfd_tunnel?is_deleted=false")"
tunnel_id="$(jq -r --arg name "$tunnel_name" '.result[] | select(.name == $name) | .id' <<<"$tunnels" | head -1)"
if [[ -z "$tunnel_id" ]]; then
    # The tunnel is usually present under another name; list what is there.
    echo "error: no tunnel named $tunnel_name in account $account" >&2
    echo "tunnels that do exist in this account:" >&2
    jq -r '.result[]? | "  \(.name)\t\(.id)\tconnections=\(.connections | length)"' <<<"$tunnels" >&2
    echo "Re-run with MONITORING_TUNNEL_NAME='<name>' once you know which one serves monitoring." >&2
    exit 1
fi

grafana_record="$(lookup_dns_record "grafana.$domain")" || die "no CNAME found for grafana.$domain"

# otel. after the rename, otlp. before it. New name first, so a re-run is a no-op.
for host in "otel.$domain" "otlp.$domain"; do
    if otel_record="$(lookup_dns_record "$host")"; then
        ingestion_host="$host"
        break
    fi
done
[[ -n "${ingestion_host:-}" ]] || die "no CNAME found for otel.$domain or otlp.$domain"

# The Access app may legitimately not exist; then the apply should create it. A
# zone-scoped app (predating account-scoped Access) cannot be adopted by the
# account-scoped resource, so that case gets its own message.
access_apps="$(api "accounts/$account/access/apps?per_page=100")"
access_app_id="$(jq -r --arg d "grafana.$domain" '.result[] | select(.domain == $d) | .id' <<<"$access_apps" | head -1)"
if [[ -z "$access_app_id" ]]; then
    zone_app_id="$(api "zones/$zone/access/apps?per_page=100" \
        | jq -r --arg d "grafana.$domain" '.result[]? | select(.domain == $d) | .id' | head -1)" || zone_app_id=""
    if [[ -n "$zone_app_id" ]]; then
        die "the Access app on grafana.$domain is zone-scoped ($zone_app_id); this root declares an
       account-scoped one. Recreate it at the account level, or give the resource
       zone_id instead of account_id, before importing."
    fi
    echo "note: no Access application on grafana.$domain; omitting its import block so the" >&2
    echo "      apply CREATES it. Until that apply lands, Grafana's hostname is protected only" >&2
    echo "      by its own login. Access apps that do exist in this account:" >&2
    jq -r '.result[]? | "  \(.name)\t\(.domain)"' <<<"$access_apps" >&2
fi

# An app built in the dashboard usually carries an inline policy with no id to
# import; the apply then creates the reusable one and reattaches the app.
access_policies="$(api "accounts/$account/access/policies")"
access_policy_id="$(jq -r '.result[] | select(.name == "monitoring: allowed emails") | .id' <<<"$access_policies" | head -1)"

echo "# Generated by generate-imports.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Delete after a successful apply."
echo "# Ingestion record adopted from $ingestion_host as cloudflare_dns_record.otel."
cat <<EOF

import {
  to = cloudflare_zero_trust_tunnel_cloudflared.monitoring
  id = "$account/$tunnel_id"
}

import {
  to = cloudflare_zero_trust_tunnel_cloudflared_config.monitoring
  id = "$account/$tunnel_id"
}

import {
  to = cloudflare_dns_record.grafana
  id = "$zone/$grafana_record"
}

import {
  to = cloudflare_dns_record.otel
  id = "$zone/$otel_record"
}
EOF

if [[ -n "$access_app_id" ]]; then
    cat <<EOF

# Provider 5.x wants the scope spelled out for this one resource: '<accounts|zones>/<id>/<app_id>'.
import {
  to = cloudflare_zero_trust_access_application.grafana
  id = "accounts/$account/$access_app_id"
}
EOF
fi

if [[ -n "$access_policy_id" ]]; then
    cat <<EOF

import {
  to = cloudflare_zero_trust_access_policy.grafana_emails
  id = "$account/$access_policy_id"
}
EOF
else
    echo "note: no reusable Access policy named 'monitoring: allowed emails'; omitting its" >&2
    echo "      import block so the apply creates it. Check the plan's include{} list against" >&2
    echo "      the emails the live app admits before applying." >&2
fi
