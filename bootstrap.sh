#!/usr/bin/env bash
# Onboard one project/environment onto this monitoring stack.
#
#   ./bootstrap.sh <project> <env>
#
# It does the four things a human would otherwise get subtly wrong:
#
#   1. renders the keystone ProjectTelemetrySilent rule and reloads Grafana;
#   2. regenerates the coverage rule, so a project that ships telemetry without ever
#      being bootstrapped is itself alerted on;
#   3. creates the project's healthchecks.io checks (if an API key is present) and
#      prints their ping URLs;
#   4. prints the `.env` block to paste on the project host, and the curl that vendors
#      the templates at a pinned tag.
#
# Bootstrap creates the safety net, not the telemetry: a host can ship perfectly good
# telemetry and still be unmonitored, because the rule that notices its silence lives
# here.
#
# Idempotent: re-running it re-renders the same files and reloads again.
set -euo pipefail

project="${1:-}"
env_name="${2:-}"
if [[ -z "$project" || -z "$env_name" ]]; then
    echo "usage: $0 <project> <env>" >&2
    exit 2
fi
# These become Prometheus label values, a Grafana rule uid, and a filename. Keep them
# boring: a label value with a quote or a brace in it produces a rule that silently
# never matches, which is the failure mode this whole stack exists to avoid.
if [[ ! "$project" =~ ^[a-z0-9][a-z0-9-]*$ || ! "$env_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "error: project and env must match [a-z0-9][a-z0-9-]* (lowercase, no spaces)" >&2
    exit 2
fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

# Read HEALTHCHECKS_API_KEY from .env if the environment does not already carry it.
# `just` recipes get .env via dotenv-load; a bare ./bootstrap.sh does not, and silently
# skipping check creation because of that is a confusing way to find out. Only this one
# key is read — sourcing the whole file would drag the stack's secrets into scope.
#
# It must be the project's READ-WRITE API key: the read-only key cannot POST, and a ping
# key only sends pings.
if [[ -z "${HEALTHCHECKS_API_KEY:-}" && -f .env ]]; then
    HEALTHCHECKS_API_KEY="$(sed -n 's/^HEALTHCHECKS_API_KEY=//p' .env | tail -1)"
    export HEALTHCHECKS_API_KEY
fi
# Flat, not a subdirectory: Grafana's alerting provisioner does not recurse, and it
# skips a directory with a warning rather than an error — so a nested layout looks like
# it worked and provisions nothing. The project- prefix keeps them grouped in `ls`.
out_dir="config/grafana/alerting"

# Pinned tag for the vendoring curl. A moving ref would let two projects vendor two
# different agent configs and call it the same template — so no fallback to a branch.
tag="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null)" \
    || { echo "error: no release tag to pin the vendoring curls to; tag a release first" >&2; exit 1; }
# ...and the tag must actually contain the templates, or every curl 404s.
git -C "$root" rev-parse -q --verify "${tag}:templates/alloy/config.alloy" >/dev/null \
    || { echo "error: tag ${tag} predates templates/; tag a new release before onboarding" >&2; exit 1; }
repo_raw="https://raw.githubusercontent.com/CMLPlatform/monitoring/${tag}/templates"

# --------------------------------------------------------------- 1. the keystone rules
# Every covered project/environment, read back from the COVERS marker each rendered file
# carries rather than from a list someone has to remember to update, plus the pair being
# bootstrapped now. The pair matters, not just the project: a project bootstrapped for
# staging that also ships prod would otherwise read as covered while prod has no
# keystone rule at all — the same silent gap one level further in.
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

# ------------------------------------------------------------------ 3. reload Grafana
if docker compose ps --status running --services 2>/dev/null | grep -qx grafana; then
    # A restart, not SIGHUP: Grafana re-reads alert provisioning only at startup, and
    # a SIGHUP reports success while changing nothing.
    docker compose up -d --force-recreate grafana >/dev/null 2>&1 \
        && echo "reloaded  grafana (restarted)" \
        || echo "WARNING: could not restart grafana; run 'docker compose up -d --force-recreate grafana'" >&2
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

Verify before executing anything — hashes taken from the ${tag} tag here, so a
repo compromise after tagging cannot silently change what project hosts run:
sha256sum -c <<'SUM'
$(for pair in "alloy/config.alloy deploy/alloy/config.alloy" \
              "compose.telemetry.yml compose.telemetry.yml" \
              "compose.telemetry.gpu.yml compose.telemetry.gpu.yml" \
              "run_scheduled.sh scripts/run_scheduled.sh"; do
      # Deliberate word splitting: each pair is "<src> <dest>".
      # shellcheck disable=SC2086
      set -- $pair
      printf '%s  %s\n' "$(git -C "$root" show "${tag}:templates/$1" | sha256sum | cut -d' ' -f1)" "$2"
  done)
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
