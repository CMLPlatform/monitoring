#!/usr/bin/env bash
# Assertions `just smoke` runs against the stack it just booted. Everything
# here lands asynchronously after Grafana's /api/health answers, so each
# assertion polls (one second, up to a minute).
set -euo pipefail

url="${SMOKE_URL:?}"
project="${SMOKE_PROJECT:?}"
dept="${DEPARTMENT:-cml}"
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

die() { echo "error: $*" >&2; exit 1; }
# Admin basic auth through curl's stdin config: argv is world-readable in ps.
gf() { printf 'user = "admin:%s"\n' "$GRAFANA_ADMIN_PASSWORD" | curl -sf -K - "$@"; }
promq() { gf -G --data-urlencode "query=$1" "$url/api/datasources/proxy/uid/prometheus/api/v1/query"; }
poll() { local n=0; until "$@"; do n=$((n + 1)); [[ $n -lt 60 ]] || return 1; sleep 1; done; }

# ------------------------------------------------------------------ provisioning
# Grafana skips a broken dashboard or a malformed alert group silently, so the
# provisioned sets must equal what the repo holds, uid for uid.
want_dash="$(jq -r .uid dashboards/*.json | sort)"
rule_files=()
for f in config/grafana/alerting/*.yaml; do
    case "$f" in */contact-points.yaml | */notification-policies.yaml) ;; *) rule_files+=("$f") ;; esac
done
want_rules="$(sed -n 's/^ *- uid: *//p' "${rule_files[@]}" | sort)"
[[ -n "$want_dash" && -n "$want_rules" ]] || die "no dashboards or alert rules in the repo to assert against"

provisioned() {
    { have_dash="$(gf "$url/api/search?type=dash-db&limit=5000" | jq -r '.[].uid' | sort)" \
        && rules="$(gf "$url/api/v1/provisioning/alert-rules")"; } \
        || die "Grafana API request failed. Check GRAFANA_ADMIN_PASSWORD, and that Grafana answers on $url"
    have_rules="$(jq -r '.[].uid' <<<"$rules" | sort)"
    [[ "$have_dash" == "$want_dash" && "$have_rules" == "$want_rules" ]]
}
poll provisioned || die "not provisioned after 60s (a malformed file provisions none of its group). See just smoke-logs
dashboards, want vs have: $(diff <(echo "$want_dash") <(echo "$have_dash") | grep '^[<>]' | tr '\n' ' ')
alert rules, want vs have: $(diff <(echo "$want_rules") <(echo "$have_rules") | grep '^[<>]' | tr '\n' ' ')"
jq -e 'all(.isPaused | not)' <<<"$rules" >/dev/null \
    || die "paused alert rules never fire: $(jq -r '.[] | select(.isPaused) | .uid' <<<"$rules" | tr '\n' ' ')"

# --------------------------------------------------------------- contact points
# The exact URLs the stack was given must come back: an empty value would
# pass a "not literally $ALERT_WEBHOOK_URL" test and drop every alert.
gf "$url/api/v1/provisioning/contact-points" \
    | jq -e --arg a "$ALERT_WEBHOOK_URL" --arg h "$HEARTBEAT_URL" \
        '[.[] | select(.uid | startswith("cp-")) | .settings.url] | sort == ([$a, $h] | sort)' >/dev/null \
    || die "contact points do not carry ALERT_WEBHOOK_URL and HEARTBEAT_URL; Grafana did not expand the provisioning file, or a receiver is missing"

# ------------------------------------------------------------------- JWT auth
# Grafana ignores an env key it no longer knows, so read the parsed setting
# back, and check that a forged Access header is refused.
gf "$url/api/admin/settings" | jq -e '.["auth.jwt"].enabled == "true"' >/dev/null \
    || die "Grafana did not enable JWT auth from GF_AUTH_JWT_*; the Cloudflare Access path is broken"
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Cf-Access-Jwt-Assertion: not-a-jwt' "$url/api/dashboards/home")"
[[ "$code" == 401 ]] || die "a forged Access token got HTTP $code from Grafana, expected 401"

# ------------------------------------------------------------- scrape targets
# A renamed service leaves its scrape job silently empty, and TargetDown then
# matches nothing. Every job in prometheus.yaml must have scraped its target.
n_jobs="$(grep -c '^ *- job_name:' config/prometheus.yaml)"
all_up() { [[ "$(promq 'count(up == 1)' | jq -r '.data.result[0].value[1] // 0')" == "$n_jobs" ]]; }
poll all_up || die "not all $n_jobs scrape targets are up: $(promq up | jq -r '.data.result[] | "\(.metric.job)=\(.value[1])"' | tr '\n' ' ')"

# ------------------------------------------------------------- data paths
# One metric and one log through the collector's bearer auth, read back with
# the identity labels the alert rules key on. Posted from inside the stack's
# network with Grafana's curl: the sandbox overlay publishes no ingestion ports.
ts="$(date +%s)000000000"
res='{"attributes":[{"key":"service.name","value":{"stringValue":"smoke"}},{"key":"project","value":{"stringValue":"smoke"}},{"key":"env","value":{"stringValue":"ci"}}]}'
# Token through curl's stdin config: argv is world-readable in ps, on the host
# and inside the container alike.
otlp() {
    docker compose -p "$project" exec -T grafana sh -c \
        'curl -sf -K - -o /dev/null -H "Content-Type: application/json" --data-binary "$1" "http://otel-collector:4318/v1/$2"' \
        _ "$2" "$1" <<<"header = \"Authorization: Bearer $OTLP_AUTH_TOKEN\""
}
otlp metrics '{"resourceMetrics":[{"resource":'"$res"',"scopeMetrics":[{"metrics":[{"name":"smoke_up","gauge":{"dataPoints":[{"asInt":"1","timeUnixNano":"'"$ts"'"}]}}]}]}]}' \
    || die "the collector refused an OTLP metric with the .env token"
otlp logs '{"resourceLogs":[{"resource":'"$res"',"scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$ts"'","body":{"stringValue":"smoke"}}]}]}]}' \
    || die "the collector refused an OTLP log with the .env token"
smoke_metric() { promq "smoke_up{job=\"smoke\",project=\"smoke\",env=\"ci\",department=\"$dept\"}" | jq -e '.data.result | length > 0' >/dev/null; }
smoke_log() {
    gf -G --data-urlencode "query={project=\"smoke\",env=\"ci\",department=\"$dept\"}" \
        "$url/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
        | jq -e 'any(.data.result[].values[][1]; . == "smoke")' >/dev/null
}
poll smoke_metric || die "the smoke metric never reached Prometheus with its project/env/department labels; see just smoke-logs"
poll smoke_log || die "the smoke log never reached Loki with its department label; see just smoke-logs"

echo "Stack healthy"
