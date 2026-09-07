#!/usr/bin/env bash
# Onboard one project/environment onto this monitoring stack.
#
#   ./bootstrap.sh <project> <env>
#
#   1. renders the ProjectTelemetrySilent rule and reloads Grafana;
#   2. regenerates the coverage rule that catches projects never bootstrapped;
#   3. creates the project's healthchecks.io checks (if an API key is present);
#   4. prints the `.env` block for the project host and the curls that vendor the
#      templates at a pinned tag.
#
# Idempotent.
set -euo pipefail

project="${1:-}"
env_name="${2:-}"
if [[ -z "$project" || -z "$env_name" ]]; then
    echo "usage: $0 <project> <env>" >&2
    exit 2
fi
# These become label values, a rule uid, and a filename; a quote or brace in a
# label value produces a rule that silently never matches.
valid_pair() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ && "$2" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
if ! valid_pair "$project" "$env_name"; then
    echo "error: project and env must match [a-z0-9][a-z0-9-]* (lowercase, no spaces)" >&2
    exit 2
fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

# A bare ./bootstrap.sh does not load .env, so read single keys out of it.
# Sourcing the whole file would drag the stack's secrets into scope.
env_get() { [[ -f .env ]] && sed -n "s/^$1=//p" .env | tail -1; }

if [[ -z "${HEALTHCHECKS_API_KEY:-}" ]]; then
    HEALTHCHECKS_API_KEY="$(env_get HEALTHCHECKS_API_KEY)"
    export HEALTHCHECKS_API_KEY
fi
# Flat, not a subdirectory: Grafana's alerting provisioner does not recurse, and
# skips a nested directory with only a warning. BOOTSTRAP_OUT_DIR is for `just
# lint`; with it set, nothing past the rendering runs.
out_dir="${BOOTSTRAP_OUT_DIR:-config/grafana/alerting}"
# The vendored templates and the paths they are printed under.
templates="alloy/config.alloy:deploy/alloy/config.alloy compose.telemetry.yml:compose.telemetry.yml compose.telemetry.gpu.yml:compose.telemetry.gpu.yml run_scheduled.sh:scripts/run_scheduled.sh"

if [[ -z "${BOOTSTRAP_OUT_DIR:-}" ]]; then
    # Pinned tag, no fallback to a branch: two projects must never vendor two
    # different configs under the same name.
    tag="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null)" \
        || { echo "error: no release tag to pin the vendoring curls to; tag a release first" >&2; exit 1; }
    # The tag must contain every template, or a curl 404s and the hash printed
    # for it below is the hash of nothing.
    for pair in $templates; do
        git -C "$root" rev-parse -q --verify "${tag}:templates/${pair%%:*}" >/dev/null \
            || { echo "error: tag ${tag} predates templates/${pair%%:*}; tag a new release before onboarding" >&2; exit 1; }
    done
    repo_raw="https://raw.githubusercontent.com/CMLPlatform/monitoring/${tag}/templates"
fi

# --------------------------------------------------------------- 1. the keystone rules
# Every covered project/env pair, read back from the COVERS marker in each
# rendered file, plus the pair being bootstrapped now.
pairs="$({ sed -n 's/^# COVERS: //p' "$out_dir"/project-*.yaml 2>/dev/null || true
           echo "$project $env_name"; } | sort -u)"
# The markers come off disk and land in a sed replacement and a PromQL label
# value. Refuse the run rather than render a rule that silently never matches;
# the fix is to delete the edited file.
while read -r p e; do
    valid_pair "$p" "$e" \
        || { echo "error: bad '# COVERS:' marker in $out_dir: '$p $e'" >&2; exit 2; }
done <<<"$pairs"

# All pairs are re-rendered, so a template fix reaches every project.
while read -r p e; do
    rendered="${out_dir}/project-${p}-${e}.yaml"
    sed -e "s/__PROJECT__/${p}/g" \
        -e "s/__ENV__/${e}/g" \
        templates/alerting/project.yaml.tmpl > "$rendered"
    echo "rendered  $rendered"
done <<<"$pairs"

# ------------------------------------------------------------ 2. the coverage backstop
covered="$(echo "$pairs" | sed 's| |/|' | paste -sd',' - | sed 's/,/, /g')"
covered_expr="$(echo "$pairs" \
    | sed 's@^\([^ ]*\) \([^ ]*\)$@{__name__=~"telemetry_.+_total", project="\1",env="\2"}@' \
    | paste -sd'@' - | sed 's/@/ or /g')"
sed -e "s@__COVERED__@${covered}@" \
    -e "s@__COVERED_EXPR__@${covered_expr}@" \
    templates/alerting/coverage.yaml.tmpl > "${out_dir}/coverage.yaml"
echo "rendered  ${out_dir}/coverage.yaml  (covering: ${covered})"
[[ -z "${BOOTSTRAP_OUT_DIR:-}" ]] || exit 0

# ------------------------------------------------------------------ 3. reload Grafana
if docker compose ps --status running --services 2>/dev/null | grep -qx grafana; then
    # This recreates an exposed Grafana, so the `just up` guards apply here too.
    just _guard-if-exposed || exit 1
    # A restart, not SIGHUP: Grafana re-reads alert provisioning only at startup.
    docker compose up -d --force-recreate grafana >/dev/null 2>&1 \
        && echo "reloaded  grafana (restarted)" \
        || echo "WARNING: could not restart grafana; run 'docker compose up -d --force-recreate grafana'" >&2
    # Grafana skips a malformed alert group with only a log line, so read the
    # rule back.
    if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
        GRAFANA_ADMIN_PASSWORD="$(env_get GRAFANA_ADMIN_PASSWORD)"
    fi
    [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] \
        || { echo "error: GRAFANA_ADMIN_PASSWORD is not set and not readable from .env; cannot verify the rule" >&2; exit 1; }
    # curl's config parser unescapes \ and " inside a quoted value, so escape both.
    gpw="${GRAFANA_ADMIN_PASSWORD//\\/\\\\}"
    gpw="${gpw//\"/\\\"}"
    uid="proj-silent-${project}-${env_name}"
    for _ in $(seq 30); do
        sleep 2
        # Password on stdin, never argv. A wrong password would otherwise poll
        # for a minute and then report the rule as missing.
        code="$(printf 'user = "admin:%s"\n' "$gpw" \
            | curl -s -o /dev/null -w '%{http_code}' -K - "http://localhost:3000/api/v1/provisioning/alert-rules/${uid}")" || continue
        case "$code" in
            200)
                echo "verified  rule ${uid} is provisioned"
                uid=""
                break
                ;;
            401 | 403)
                echo "error: grafana rejected the admin credentials (HTTP ${code}); check GRAFANA_ADMIN_PASSWORD" >&2
                exit 1
                ;;
        esac
    done
    [[ -z "$uid" ]] || { echo "error: grafana restarted but rule ${uid} is not provisioned; check 'just logs grafana' for the rejected file" >&2; exit 1; }
else
    echo "note      grafana is not running; the rules apply next time it starts"
fi

# ------------------------------------------------------- 4. healthchecks.io + printout
if [[ -n "${HEALTHCHECKS_API_KEY:-}" ]]; then
    # Default job set; override per project with HC_JOBS="backup nightly-sync" etc.
    for job in ${HC_JOBS:-backup watchdog restore-check}; do
        # Key via curl's stdin config, not -H: argv is readable in `ps`.
        printf 'header = "X-Api-Key: %s"\n' "$HEALTHCHECKS_API_KEY" \
            | curl -fsS -K - -X POST https://healthchecks.io/api/v3/checks/ \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${project}-${env_name}-${job}\",\"slug\":\"${project}-${env_name}-${job}\",\"unique\":[\"name\"],\"timeout\":93600,\"grace\":3600,\"channels\":\"*\"}" \
            | sed -n 's/.*"ping_url": *"\([^"]*\)".*/  PING_'"$(echo "$job" | tr 'a-z-' 'A-Z_')"'=\1/p'
    done
else
    echo "note      HEALTHCHECKS_API_KEY unset; create these by hand at https://healthchecks.io and note their ping URLs"
fi

# Computed before the heredoc: a substitution inside `cat <<EOF` cannot fail
# the script, and a missing template would print sha256("") as authoritative.
hashes=""
curls=""
for pair in $templates; do
    sum="$(git -C "$root" show "${tag}:templates/${pair%%:*}" | sha256sum | cut -d' ' -f1)"
    hashes="${hashes}${sum}  ${pair#*:}"$'\n'
    curls+="$(printf 'curl -fsSL -o %-24s %s/%s' "${pair#*:}" "$repo_raw" "${pair%%:*}")"$'\n'
done
hashes="${hashes%$'\n'}"
curls="${curls%$'\n'}"

cat <<SUMMARY

────────────────────────────────────────────────────────────────────────────
Paste this into the project host's root .env
────────────────────────────────────────────────────────────────────────────
PROJECT=${project}
ENVIRONMENT=${env_name}
OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-hostname>
OTLP_AUTH_TOKEN=<the stack's shared ingest token>
TELEMETRY_EDGE_KEY=            # only if the project's egress crosses a WAF
GPU_METRICS=                   # 1 on a host with an NVIDIA card, read by your deploy
                               # tooling to include compose.telemetry.gpu.yml

────────────────────────────────────────────────────────────────────────────
Vendor the templates on the project host (pinned at ${tag})
────────────────────────────────────────────────────────────────────────────
mkdir -p deploy/alloy scripts
${curls}

Verify before executing anything (the hashes come from the ${tag} tag):
sha256sum -c <<'SUM'
${hashes}
SUM
chmod +x scripts/run_scheduled.sh

Then include the overlay and bring it up:
  docker compose -f compose.yml -f compose.telemetry.yml up -d

Verify from the monitoring host, within ~2 minutes:
  count(telemetry_datapoints_total{project="${project}",env="${env_name}"})  -> non-zero
  count(container_start_time_seconds{project="${project}",name!=""})  -> one per container
SUMMARY
