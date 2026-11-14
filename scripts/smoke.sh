#!/usr/bin/env bash
# Assertions `just smoke` runs against the stack it just booted. Everything
# here lands asynchronously after Grafana's /api/health answers, so each
# assertion polls (one second, up to a minute).
set -euo pipefail

url="${SMOKE_URL:?}"
project="${SMOKE_PROJECT:?}"
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

die() { echo "error: $*" >&2; exit 1; }
# curl's config parser unescapes \ and " inside a quoted value, so escape both.
cfg_quote() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }
# Admin basic auth through curl's stdin config: argv is world-readable in ps.
gf() { printf 'user = "admin:%s"\n' "$(cfg_quote "$GRAFANA_ADMIN_PASSWORD")" | curl -sf -K - "$@"; }
promq() { gf -G --data-urlencode "query=$1" "$url/api/datasources/proxy/uid/prometheus/api/v1/query"; }
poll() { local n=0; until "$@"; do n=$((n + 1)); [[ $n -lt ${POLL_MAX:-60} ]] || return 1; sleep "${POLL_SLEEP:-1}"; done; }

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
# External notification credentials belong to the relay, outside Grafana.
gf "$url/api/v1/provisioning/contact-points" \
    | jq -e --arg a "http://notification-relay:8080/alerts" --arg h "http://notification-relay:8080/heartbeat" \
        '[.[] | select(.uid | startswith("cp-")) | .settings.url] | sort == ([$a, $h] | sort)' >/dev/null \
    || die "contact points do not target the internal notification relay"

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
all_up() {
    [[ "$(promq 'count(count by (job) (up == 1))' | jq -r '.data.result[0].value[1] // 0')" == "$n_jobs" ]] \
        && [[ "$(promq 'count(up == 0)' | jq -r '.data.result[0].value[1] // 0')" == "0" ]]
}
poll all_up || die "not all $n_jobs scrape targets are up: $(promq up | jq -r '.data.result[] | "\(.metric.job)=\(.value[1])"' | tr '\n' ' ')"

# The alert-pipeline check below waits out TargetDown's `for`. Stopping its target
# here lets that clock run during the data-path checks, none of which scrape it.
if [[ "${SMOKE_ALERTS:-}" == 1 ]]; then
    docker compose -p "$project" stop -t 1 node-exporter >/dev/null
fi

# ------------------------------------------------------------- data paths
# One metric, log and trace through the collector's bearer auth, read back with
# the identity labels the alert rules key on. Posted from inside the stack's
# network with Grafana's curl: the sandbox overlay publishes no ingestion ports.
run_start="$(date +%s)"
ts="${run_start}000000000"
# A fresh value/body distinguishes this run without adding unbounded labels.
smoke_value="$(od -An -N6 -tu8 /dev/urandom | tr -d ' ')"
smoke_body="smoke $smoke_value"
trace_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
span_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
# Tempo returns OTLP JSON byte IDs as base64, unlike the hex lookup URL.
# shellcheck disable=SC2001 # Convert hex byte pairs, rather than literal text.
trace_b64="$(printf '%b' "$(sed 's/../\\x&/g' <<<"$trace_id")" | base64 | tr -d '\n')"
# shellcheck disable=SC2001 # Convert hex byte pairs, rather than literal text.
span_b64="$(printf '%b' "$(sed 's/../\\x&/g' <<<"$span_id")" | base64 | tr -d '\n')"
counts_query='sum by (__name__) ({__name__=~"telemetry_(datapoints|logs|spans)_total",project="smoke",env="ci"})'
counts_before="$(promq "$counts_query" | jq '[.data.result[] | {key: .metric.__name__, value: (.value[1] | tonumber)}] | from_entries')"
res='{"attributes":[{"key":"service.name","value":{"stringValue":"smoke"}},{"key":"project","value":{"stringValue":"smoke"}},{"key":"env","value":{"stringValue":"ci"}}]}'
# Token through curl's stdin config: argv is world-readable in ps, on the host
# and inside the container alike.
otlp() {
    docker compose -p "$project" exec -T grafana sh -c \
        'curl -sf -K - -o /dev/null -H "Content-Type: application/json" --data-binary "$1" "http://otel-collector:4318/v1/$2"' \
        _ "$2" "$1" <<<"header = \"Authorization: Bearer $(cfg_quote "$OTLP_AUTH_TOKEN")\""
}
otlp metrics '{"resourceMetrics":[{"resource":'"$res"',"scopeMetrics":[{"metrics":[{"name":"smoke_up","gauge":{"dataPoints":[{"asInt":"'"$smoke_value"'","timeUnixNano":"'"$ts"'"}]}}]}]}]}' \
    || die "the collector refused an OTLP metric with the .env token"
otlp logs '{"resourceLogs":[{"resource":'"$res"',"scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$ts"'","body":{"stringValue":"'"$smoke_body"'"}}]}]}]}' \
    || die "the collector refused an OTLP log with the .env token"
otlp traces '{"resourceSpans":[{"resource":'"$res"',"scopeSpans":[{"spans":[{"traceId":"'"$trace_id"'","spanId":"'"$span_id"'","name":"smoke","kind":1,"startTimeUnixNano":"'"$ts"'","endTimeUnixNano":"'"$((run_start + 1))000000000"'"}]}]}]}' \
    || die "the collector refused an OTLP trace with the .env token"
smoke_metric() { promq "timestamp(smoke_up{job=\"smoke\",project=\"smoke\",env=\"ci\",department=\"cml\"} == $smoke_value) >= $run_start" | jq -e '.data.result | length > 0' >/dev/null; }
smoke_log() {
    gf -G --data-urlencode "query={project=\"smoke\",env=\"ci\",department=\"cml\"}" \
        --data-urlencode "start=$ts" --data-urlencode "end=$(date +%s)000000000" \
        "$url/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
        | jq -e --arg body "$smoke_body" 'any(.data.result[].values[][1]; . == $body)' >/dev/null
}
smoke_trace() {
    gf -H 'Accept: application/json' "$url/api/datasources/proxy/uid/tempo/api/traces/$trace_id" \
        | jq -e --arg trace "$trace_b64" --arg span "$span_b64" '
            any(.batches[];
                (.resource.attributes | map({key: .key, value: .value.stringValue}) | from_entries) as $a
                | $a.project == "smoke" and $a.env == "ci" and $a.department == "cml"
                and any(.scopeSpans[].spans[]; .traceId == $trace and .spanId == $span and .name == "smoke"))' >/dev/null
}
poll smoke_metric || die "the smoke metric never reached Prometheus with its project/env/department labels; see just smoke-logs"
poll smoke_log || die "the smoke log never reached Loki with its department label; see just smoke-logs"
poll smoke_trace || die "the smoke trace never reached Tempo with its trace/span identity and project/env/department attributes; see just smoke-logs"
# The keystone alert (ProjectTelemetrySilent) and the coverage backstop key on the
# gateway's ingest counters, so a renamed metric or a dropped attribute would
# silence both without any other assertion noticing.
counted() {
    promq "$counts_query" | jq -e --argjson before "$counts_before" '
        [.data.result[] | {key: .metric.__name__, value: (.value[1] | tonumber)}] | from_entries
        | . as $after | ["telemetry_datapoints_total", "telemetry_logs_total", "telemetry_spans_total"]
        | all(.[]; . as $name | ($after[$name] // 0) > ($before[$name] // 0))' >/dev/null
}
poll counted || die "the count connector never advanced all three telemetry signal counters for this smoke run; the alert rules that key on it would never fire"

# ------------------------------------------------------------- ntfy & blackbox
# Verify ntfy health endpoint answers over the docker network.
ntfy_healthy() {
    docker compose -p "$project" exec -T grafana curl -sf "http://ntfy:80/v1/health" >/dev/null
}
poll ntfy_healthy || die "ntfy health endpoint did not respond on internal port 80"

# Verify blackbox prober recorded probe duration metrics from file discovery.
blackbox_probed() {
    promq 'probe_duration_seconds{job="blackbox", project="cml-gallery"}' | jq -e '.data.result | length > 0' >/dev/null
}
poll blackbox_probed || die "blackbox probe metrics for cml-gallery never reached Prometheus; check blackbox-exporter and file_sd_configs"

# ------------------------------------------------------------- alert pipeline
# Opt-in (SMOKE_ALERTS=1): node-exporter was stopped after the scrape-target
# check; wait for TargetDown to reach firing. Costs the rule's `for` (2m) plus an
# evaluation, so it is off for the local loop and on in CI. Guards the
# threshold-node contract in rules.yaml: a query whose matching value is 0 never
# fires without `bool`.
if [[ "${SMOKE_ALERTS:-}" == 1 ]]; then
    target_down_firing() {
        gf "$url/api/prometheus/grafana/api/v1/rules" \
            | jq -e '.data.groups[].rules[] | select(.name == "TargetDown") | .state == "firing"' >/dev/null
    }
    POLL_MAX=60 POLL_SLEEP=5 poll target_down_firing || die "TargetDown did not fire within 5 minutes of stopping node-exporter"
    docker compose -p "$project" start node-exporter >/dev/null
    node_recovered() {
        promq 'up{job="node"}' | jq -e '.data.result | length > 0 and all(.[]; .value[1] == "1")' >/dev/null
    }
    target_down_normal() {
        gf "$url/api/prometheus/grafana/api/v1/rules" \
            | jq -e '.data.groups[].rules[] | select(.name == "TargetDown") | .state == "inactive"' >/dev/null
    }
    poll node_recovered || die "node-exporter did not resume scraping within a minute of restart"
    POLL_MAX=60 POLL_SLEEP=5 poll target_down_normal || die "TargetDown did not return to normal within 5 minutes of restarting node-exporter"
    echo "TargetDown fired, node-exporter resumed scraping, and TargetDown returned to normal"
fi

echo "Stack healthy"
