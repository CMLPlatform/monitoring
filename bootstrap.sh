#!/usr/bin/env bash
# Onboard one project/environment onto this monitoring stack.
#
#   ./bootstrap.sh <project> <env>
#
# It does four things:
#
#   1. renders the keystone ProjectTelemetrySilent rule and reloads Grafana;
#   2. regenerates the coverage rule, so a project that ships telemetry without ever
#      being bootstrapped is itself alerted on;
#   3. creates the project's healthchecks.io checks (if an API key is present) and
#      prints their ping URLs;
#   4. prints the `.env` block to paste on the project host, and the curl that vendors
#      the templates at a pinned tag.
#
# Bootstrap creates the safety net, not the telemetry. A host can ship good telemetry
# and still be unmonitored, because the rule that notices its silence lives here.
#
# Idempotent: re-running it re-renders the same files and reloads again.
set -euo pipefail

project="${1:-}"
env_name="${2:-}"
if [[ -z "$project" || -z "$env_name" ]]; then
    echo "usage: $0 <project> <env>" >&2
    exit 2
fi
# These become Prometheus label values, a Grafana rule uid, and a filename. A quote or a
# brace in a label value produces a rule that silently never matches.
if [[ ! "$project" =~ ^[a-z0-9][a-z0-9-]*$ || ! "$env_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "error: project and env must match [a-z0-9][a-z0-9-]* (lowercase, no spaces)" >&2
    exit 2
fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

# Read HEALTHCHECKS_API_KEY from .env if the environment does not already carry it.
# `just` recipes get .env via dotenv-load; a bare ./bootstrap.sh does not, and would then
# skip check creation without saying why. Only this one key is read: sourcing the whole
# file would drag the stack's secrets into scope.
#
# It must be the project's READ-WRITE API key. The read-only key cannot POST, and a ping
# key only sends pings.
if [[ -z "${HEALTHCHECKS_API_KEY:-}" && -f .env ]]; then
    HEALTHCHECKS_API_KEY="$(sed -n 's/^HEALTHCHECKS_API_KEY=//p' .env | tail -1)"
    export HEALTHCHECKS_API_KEY
fi
# Flat, not a subdirectory: Grafana's alerting provisioner does not recurse. It skips a
# nested directory with a warning, not an error, so that layout looks like it worked and
# provisions nothing. The project- prefix keeps the files grouped in `ls`.
# BOOTSTRAP_OUT_DIR is for `just lint`: it renders the templates into a scratch dir and
# lints the result, so a template edit that Grafana would reject fails in CI instead of
# on the next onboarding. With it set, nothing past the rendering runs.
out_dir="${BOOTSTRAP_OUT_DIR:-config/grafana/alerting}"
# The vendored templates and the paths they are printed under, used twice below.
templates="alloy/config.alloy:deploy/alloy/config.alloy compose.telemetry.yml:compose.telemetry.yml compose.telemetry.gpu.yml:compose.telemetry.gpu.yml run_scheduled.sh:scripts/run_scheduled.sh"

if [[ -z "${BOOTSTRAP_OUT_DIR:-}" ]]; then
    # Pinned tag for the vendoring curl, with no fallback to a branch. A moving ref would
    # let two projects vendor two different agent configs and call it the same template.
    tag="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null)" \
        || { echo "error: no release tag to pin the vendoring curls to; tag a release first" >&2; exit 1; }
    # The tag must also contain every template, or a curl 404s and the hash printed for
    # it below is the hash of nothing.
    for pair in $templates; do
        git -C "$root" rev-parse -q --verify "${tag}:templates/${pair%%:*}" >/dev/null \
            || { echo "error: tag ${tag} predates templates/${pair%%:*}; tag a new release before onboarding" >&2; exit 1; }
    done
    repo_raw="https://raw.githubusercontent.com/CMLPlatform/monitoring/${tag}/templates"
fi

# --------------------------------------------------------------- 1. the keystone rules
# Every covered project/environment, read back from the COVERS marker in each rendered
# file, plus the pair being bootstrapped now. No hand-maintained list to fall behind.
#
# The pair matters, not just the project. A project bootstrapped for staging that also
# ships prod would otherwise read as covered while prod has no keystone rule at all.
pairs="$({ sed -n 's/^# COVERS: //p' "$out_dir"/project-*.yaml 2>/dev/null || true
           echo "$project $env_name"; } | sort -u)"

# ALL pairs are re-rendered, not just the invoked one, so a template fix propagates to
# every project on the next bootstrap run instead of waiting for a per-project re-run.
while read -r p e; do
    rendered="${out_dir}/project-${p}-${e}.yaml"
    sed -e "s/__PROJECT__/${p}/g" \
        -e "s/__ENV__/${e}/g" \
        -e "s/__UID__/proj-silent-${p}-${e}/g" \
        templates/alerting/project.yaml.tmpl > "$rendered"
    echo "rendered  $rendered"
done <<<"$pairs"

# ------------------------------------------------------------ 2. the coverage backstop
covered="$(echo "$pairs" | sed 's| |/|' | paste -sd',' - | sed 's/,/, /g')"
covered_expr="$(echo "$pairs" \
    | sed 's|^\([^ ]*\) \([^ ]*\)$|{project="\1",env="\2"}|' \
    | paste -sd'|' - | sed 's/|/ or /g')"
sed -e "s@__COVERED__@${covered}@" \
    -e "s@__COVERED_EXPR__@${covered_expr}@" \
    templates/alerting/coverage.yaml.tmpl > "${out_dir}/coverage.yaml"
echo "rendered  ${out_dir}/coverage.yaml  (covering: ${covered})"
[[ -z "${BOOTSTRAP_OUT_DIR:-}" ]] || exit 0

# ------------------------------------------------------------------ 3. reload Grafana
if docker compose ps --status running --services 2>/dev/null | grep -qx grafana; then
    # A restart, not SIGHUP: Grafana re-reads alert provisioning only at startup, and
    # a SIGHUP reports success while changing nothing.
    docker compose up -d --force-recreate grafana >/dev/null 2>&1 \
        && echo "reloaded  grafana (restarted)" \
        || echo "WARNING: could not restart grafana; run 'docker compose up -d --force-recreate grafana'" >&2
    # A restart is not proof: Grafana skips a malformed alert group with a log line and
    # comes up healthy without it. Read the rule back. Same single-key read as the
    # healthchecks key above, for the same reason.
    if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" && -f .env ]]; then
        GRAFANA_ADMIN_PASSWORD="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' .env | tail -1)"
    fi
    uid="proj-silent-${project}-${env_name}"
    for _ in $(seq 30); do
        sleep 2
        if printf 'user = "admin:%s"\n' "$GRAFANA_ADMIN_PASSWORD" \
            | curl -sf -K - "http://localhost:3000/api/v1/provisioning/alert-rules/${uid}" >/dev/null; then
            echo "verified  rule ${uid} is provisioned"
            uid=""
            break
        fi
    done
    [[ -z "$uid" ]] || { echo "error: grafana restarted but rule ${uid} is not provisioned; check 'just logs grafana' for the rejected file" >&2; exit 1; }
else
    echo "note      grafana is not running; the rules apply next time it starts"
fi

# ------------------------------------------------------- 4. healthchecks.io + printout
hc_note="create these by hand at https://healthchecks.io and note their ping URLs"
if [[ -n "${HEALTHCHECKS_API_KEY:-}" ]]; then
    hc_note="created via API"
    # Default job set; override per project with HC_JOBS="backup nightly-sync" etc.
    for job in ${HC_JOBS:-backup watchdog restore-check}; do
        # API key via curl's stdin config, not -H: argv is readable in `ps` by
        # any local user, and this is a read-write key.
        printf 'header = "X-Api-Key: %s"\n' "$HEALTHCHECKS_API_KEY" \
            | curl -fsS -K - -X POST https://healthchecks.io/api/v3/checks/ \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${project}-${env_name}-${job}\",\"slug\":\"${project}-${env_name}-${job}\",\"unique\":[\"name\"],\"timeout\":93600,\"grace\":3600,\"channels\":\"*\"}" \
            | sed -n 's/.*"ping_url": *"\([^"]*\)".*/  PING_'"$(echo "$job" | tr 'a-z-' 'A-Z_')"'=\1/p'
    done
else
    echo "note      HEALTHCHECKS_API_KEY unset; ${hc_note}"
fi

# Computed before the heredoc: a substitution inside `cat <<EOF` cannot fail the script,
# and a missing template would print sha256("") as if it were authoritative.
hashes=""
for pair in $templates; do
    sum="$(git -C "$root" show "${tag}:templates/${pair%%:*}" | sha256sum | cut -d' ' -f1)"
    hashes="${hashes}${sum}  ${pair#*:}"$'\n'
done
hashes="${hashes%$'\n'}"

cat <<SUMMARY

────────────────────────────────────────────────────────────────────────────
Paste this into the project host's root .env
────────────────────────────────────────────────────────────────────────────
PROJECT=${project}
ENVIRONMENT=${env_name}
OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-hostname>
OTLP_AUTH_TOKEN=<the stack's shared ingest token>
TELEMETRY_EDGE_KEY=            # only if the project's egress crosses a WAF
GPU_METRICS=                   # 1 on hosts with an NVIDIA card

────────────────────────────────────────────────────────────────────────────
Vendor the templates on the project host (pinned at ${tag})
────────────────────────────────────────────────────────────────────────────
mkdir -p deploy/alloy scripts
curl -fsSL -o deploy/alloy/config.alloy   ${repo_raw}/alloy/config.alloy
curl -fsSL -o compose.telemetry.yml       ${repo_raw}/compose.telemetry.yml
curl -fsSL -o compose.telemetry.gpu.yml   ${repo_raw}/compose.telemetry.gpu.yml
curl -fsSL -o scripts/run_scheduled.sh    ${repo_raw}/run_scheduled.sh

Verify before executing anything. The hashes come from the ${tag} tag, so a
repo compromise after tagging cannot silently change what project hosts run:
sha256sum -c <<'SUM'
${hashes}
SUM
chmod +x scripts/run_scheduled.sh

Then include the overlay and bring it up:
  docker compose -f compose.yml -f compose.telemetry.yml up -d

The agent container needs 'cgroup: host' (the overlay sets it). Without it cAdvisor
reports the root cgroup only, and every container alert here matches nothing.

Verify from the monitoring host, within ~2 minutes:
  count({project="${project}",env="${env_name}"})            -> non-zero
  count(container_start_time_seconds{project="${project}",name!=""})  -> one per container
SUMMARY
