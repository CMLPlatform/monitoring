#!/usr/bin/env bash
# Emit OpenTofu `import` blocks for the Cloudflare resources that already exist.
#
# This root was added after the edge already existed, so its first plan against an
# empty state says "create" for objects that are already serving traffic. Applying
# that plan mints a SECOND tunnel beside `cml-monitoring`, and DNS records that fight
# the live ones. Import blocks make the adoption reviewable: read the generated file,
# then the plan, and only then apply.
#
# The ingestion record was renamed from `otlp.<domain>` to `otel.<domain>` (2026-09).
# On a state that predates the rename, the block below imports the live record as
# `cloudflare_dns_record.otel`, so the apply RENAMES it in place instead of creating a
# second one. That is also why main.tf has no `moved` block: nothing was ever in state
# under the old resource name. A current state already holds `otel.`.
#
# The generated imports.tf is a throwaway, NOT something to commit: it names one
# account's resource ids and is meaningless after the apply that consumes it. Delete it
# once the apply has succeeded. Import blocks are a one-time instruction, and leaving
# them in place re-runs them on every plan.
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
    # The token rides a curl config read from stdin, not argv: /proc/<pid>/cmdline is
    # readable by every local user for the life of each call.
    curl -fsS --config - "https://api.cloudflare.com/client/v4/$1" \
        <<<"header = \"Authorization: Bearer ${CLOUDFLARE_API_TOKEN}\""
}

command -v jq >/dev/null || die "jq is required"
: "${CLOUDFLARE_API_TOKEN:?is not set}"

# Read the ids from terraform.tfvars, which already holds them. A second source of the
# same value is a second chance to get it wrong. An exported environment variable still
# wins.
[[ -f terraform.tfvars ]] || die "no terraform.tfvars here; copy terraform.tfvars.example and fill it in"
tfvar() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" terraform.tfvars | tail -1
}
account="${TF_VAR_account_id:-$(tfvar account_id)}"
zone="${TF_VAR_zone_id:-$(tfvar zone_id)}"
domain="${TF_VAR_domain:-$(tfvar domain)}"

# The example file's placeholders are valid-looking strings, so a plan run against them
# looks plausible. Catch them here, where the message can name the line to edit.
for pair in "account_id:$account" "zone_id:$zone" "domain:$domain"; do
    value="${pair#*:}"
    [[ -n "$value" ]] || die "${pair%%:*} is empty in terraform.tfvars"
    case "$value" in
        your-* | example.org) die "${pair%%:*} is still the placeholder from terraform.tfvars.example" ;;
    esac
done

# One lookup per resource kind. Each fails loudly when the resource is absent: a silently
# skipped import comes back as a "create" in the plan.
lookup_dns_record() {
    local hostname="$1" id
    # Type-filtered: this root manages CNAMEs, and a name can also carry TXT records.
    # An unfiltered .result[0] could bind one of those, and the apply would rewrite it
    # into a proxied CNAME, destroying the TXT record and leaving the CNAME unmanaged.
    # Two statements, not one pipeline: this function only runs inside `if`/`||`, where
    # errexit is off, so a failed API call would otherwise fall through and be reported
    # as "no record", the one answer that sends the operator off to create a duplicate.
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
    # List what IS there. The tunnel is rarely absent; it is usually called something
    # else, and then the fix is one flag.
    echo "error: no tunnel named $tunnel_name in account $account" >&2
    echo "tunnels that do exist in this account:" >&2
    jq -r '.result[]? | "  \(.name)\t\(.id)\tconnections=\(.connections | length)"' <<<"$tunnels" >&2
    echo "Re-run with MONITORING_TUNNEL_NAME='<name>' once you know which one serves monitoring." >&2
    exit 1
fi

grafana_record="$(lookup_dns_record "grafana.$domain")" || die "no CNAME found for grafana.$domain"

# Still otlp. before the rename, otel. after it (or on a re-run). Try the new name first,
# so a second run is a no-op instead of resurrecting the old record.
for host in "otel.$domain" "otlp.$domain"; do
    if otel_record="$(lookup_dns_record "$host")"; then
        ingestion_host="$host"
        break
    fi
done
[[ -n "${ingestion_host:-}" ]] || die "no CNAME found for otel.$domain or otlp.$domain"

# Unlike the tunnel and the DNS records, the Access app may legitimately not exist, and
# then the apply SHOULD create it: an unprotected Grafana hostname is what this root
# exists to close. So warn, omit the import, and let the plan create it.
#
# Checked at both scopes. Apps predating account-scoped Access live under the zone, and
# one found there cannot be adopted by this resource as written (it is configured with
# account_id), so that case gets its own message instead of a silent create.
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

# The policy may also be absent: an app built in the dashboard usually carries an INLINE
# policy, which has no id to import. The apply then creates the reusable policy this root
# declares and reattaches the app to it.
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
