set dotenv-load

# Stateful services and their volumes, shared by backup/restore. The volume
# names assume the compose project name "monitoring" (see guard in backup).
stateful := "grafana prometheus loki tempo"
backup_mounts := "-v monitoring_grafana_data:/data/grafana -v monitoring_prometheus_data:/data/prometheus -v monitoring_loki_data:/data/loki -v monitoring_tempo_data:/data/tempo"

# `demo` and `smoke` each bring up a throwaway copy of the core stack, so both
# run under their own compose project and their own Grafana port (see
# compose.sandbox.yml). Neither can adopt, recreate or delete the containers and
# volumes of a stack already running on this host: `just demo` on the production
# box spins up its own Grafana next to the real one instead of joining it. The
# explicit -f list also keeps a host's COMPOSE_FILE (tunnel) out of both.
demo_project := "monitoring-demo"
demo_port := env("DEMO_PORT", "3002")
demo_url := "http://localhost:" + demo_port
compose_demo := "SANDBOX_PORT=" + demo_port + " docker compose -p " + demo_project + " -f compose.yml -f compose.demo.yml -f compose.sandbox.yml"

# What compose will actually name the project for the up-paths, so the queue
# volume gets chowned where the collector will look for it.
core_project := env("COMPOSE_PROJECT_NAME", "monitoring")

# Same isolation for smoke, on its own project and port so a smoke run and a
# demo stack can also coexist.
smoke_project := "monitoring-smoke"
smoke_port := env("SMOKE_PORT", "3001")
smoke_url := "http://localhost:" + smoke_port
compose_smoke := "SANDBOX_PORT=" + smoke_port + " docker compose -p " + smoke_project + " -f compose.yml -f compose.sandbox.yml"

# dashboards/*.json as the paths they get when mounted at /dashboards, shared
# by check and smoke. 2>/dev/null so an empty dashboards/ doesn't abort every
# recipe in this file, including the teardown ones.
dash_paths := `ls dashboards/*.json 2>/dev/null | sed 's|^dashboards|/dashboards|' | tr '\n' ' '`

default:
    @just --list

# backup/restore mount volumes by literal name, which assumes compose's default
# project name (compose.yml sets `name: monitoring`). COMPOSE_PROJECT_NAME
# overrides it, so they would silently target volumes nothing uses.
_project-guard:
    @[ -z "${COMPOSE_PROJECT_NAME:-}" ] || { echo "error: COMPOSE_PROJECT_NAME is set; this recipe expects the monitoring_* volume names" >&2; exit 1; }

# The collector's queue volume must be writable by the image's uid 10001, but
# a fresh named volume is root-owned and the image is distroless (no chown at
# startup possible). Idempotent, so every up-path just runs it. Takes the
# project name because smoke brings the stack up under a different one.
_queue-volume project:
    @docker volume create {{project}}_otel_queue > /dev/null
    @docker run --rm --network none -v {{project}}_otel_queue:/q alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b chown 10001:10001 /q

# Overlays are host config: COMPOSE_FILE in .env names the file set (see
# .env.example), and every recipe here — up, down, logs, ps, backup — acts on
# that same set. With the tunnel overlay active, this refuses to start until the
# exposure guards pass.
# Start the stack (Grafana at http://localhost:3000).
up: (_queue-volume core_project) _guard-if-exposed
    docker compose up -d

# The exposure guards, but only when the tunnel overlay is in play. Shared by
# every recipe that can put a service back on the tunnel.
_guard-if-exposed:
    @case "${COMPOSE_FILE:-}" in *compose.tunnel.yml*) just _expose-guards;; esac

# Refuses to expose the stack with the documented default credentials.
_expose-guards:
    @[ "${OTLP_AUTH_TOKEN:-}" != "local-dev-token" ] || { echo "error: OTLP_AUTH_TOKEN is still the local default; generate one (openssl rand -hex 32) before exposing ingestion" >&2; exit 1; }
    @[ "${GRAFANA_ADMIN_PASSWORD:-}" != "change-me" ] || { echo "error: GRAFANA_ADMIN_PASSWORD is still the documented default; change it before exposing Grafana" >&2; exit 1; }
    @[ "${GRAFANA_ROOT_URL:-}" != "http://localhost:3000" ] || { echo "error: GRAFANA_ROOT_URL is still the localhost default; set it to the tunnel hostname or every absolute URL Grafana generates breaks" >&2; exit 1; }
    @[ "${GRAFANA_COOKIE_SECURE:-false}" = "true" ] || { echo "error: GRAFANA_COOKIE_SECURE must be true when Grafana is served over HTTPS; set it in .env" >&2; exit 1; }
    @[ "${GRAFANA_JWT_AUTH:-false}" != "true" ] || { [ -n "${CF_ACCESS_TEAM_DOMAIN:-}" ] && [ -n "${CF_ACCESS_AUD:-}" ]; } || { echo "error: GRAFANA_JWT_AUTH=true needs CF_ACCESS_TEAM_DOMAIN and CF_ACCESS_AUD in .env (cd infra && tofu output -raw grafana_access_aud)" >&2; exit 1; }
    @[ -n "${HEARTBEAT_URL:-}" ] || echo "WARNING: HEARTBEAT_URL is empty; the stack goes live without a dead-man's switch" >&2
    @[ -n "${ALERT_WEBHOOK_URL:-}" ] || { echo "error: ALERT_WEBHOOK_URL is empty; every alert would fire into an empty url_file and be dropped. The heartbeat keeps pinging either way, so this failure looks healthy from the outside — set it, or comment out this guard deliberately" >&2; exit 1; }

down:
    docker compose down --remove-orphans

# See compose.demo.yml; watch it arrive at http://localhost:3002 (DEMO_PORT) —
# its own Grafana, not the one `just up` serves on :3000.
# Core stack plus a demo telemetry source, isolated from any running stack.
demo: (_queue-volume demo_project)
    {{compose_demo}} up -d --build

# Used by CI to catch a broken demo app before it merges.
# Build the demo image without starting anything.
demo-build:
    {{compose_demo}} build

# Removes only the demo services; the demo project's own core stack keeps
# running. `just demo-destroy` takes the whole thing down.
# Stop the demo telemetry source.
demo-down:
    {{compose_demo}} rm -sf demo-api demo-load

# Safe: -p scopes it to the demo project, so it cannot touch a real stack on
# the same host.
# Tear down the whole demo stack and its throwaway volumes.
demo-destroy:
    {{compose_demo}} down --remove-orphans --volumes

logs service="":
    docker compose logs -f {{service}}

ps:
    docker compose ps

# Targets the COMPOSE_FILE set; demo services are recreated with `just demo`.
# Restart one service.
restart service: _guard-if-exposed
    docker compose restart {{service}}

pull:
    docker compose pull

# Tail a service's logs as JSON, decoded. Useful before Grafana is set up.
tail service:
    docker compose logs -f --no-log-prefix {{service}} | jq -R 'fromjson? // .'

# All validators run in containers — no host installs, no network. The
# promtool/otelcol images are read from compose.yml so they can't drift from
# the versions the stack actually runs.
# Validate every config in the repo.
check:
    docker compose config -q
    CLOUDFLARE_TUNNEL_TOKEN=dummy docker compose -f compose.yml -f compose.tunnel.yml config -q
    {{compose_demo}} config -q
    {{compose_smoke}} config -q
    images="$(docker compose config --images)" && \
      docker run --rm --network none -v ./config/prometheus.yaml:/etc/prometheus/prometheus.yaml:ro --entrypoint promtool $(echo "$images" | grep prom/prometheus) check config /etc/prometheus/prometheus.yaml && \
      docker run --rm --network none -e OTLP_AUTH_TOKEN=dummy -e DEPARTMENT=dummy -v ./config/otel-collector.yaml:/etc/otelcol/config.yaml:ro $(echo "$images" | grep opentelemetry-collector) validate --config=/etc/otelcol/config.yaml && \
      docker run --rm --network none -v ./config/loki.yaml:/etc/loki/loki.yaml:ro $(echo "$images" | grep grafana/loki) -config.file=/etc/loki/loki.yaml -verify-config && \
      docker run --rm --network none -v ./config/tempo.yaml:/etc/tempo/tempo.yaml:ro $(echo "$images" | grep grafana/tempo) -config.file=/etc/tempo/tempo.yaml -config.verify=true
    # line-length at 120, not the default 80: digest-pinned image refs need
    # ~130 but count as non-breakable mappings. The rendered project-*/coverage
    # rules are ignored — machine-written by bootstrap.sh, their expr lines
    # grow with every onboarded project.
    docker run --rm --network none -v .:/code:ro pipelinecomponents/yamllint:0.35.13 yamllint -d '{extends: relaxed, rules: {line-length: {max: 120, allow-non-breakable-inline-mappings: true}}, ignore: [.git/, backups/, infra/.terraform/, config/grafana/alerting/project-*.yaml, config/grafana/alerting/coverage.yaml]}' .
    docker run --rm --network none -v .:/repo:ro -w /repo rhysd/actionlint:1.7.12 -color
    docker run --rm --network none -v .:/mnt:ro koalaman/shellcheck:v0.11.0 bootstrap.sh templates/run_scheduled.sh
    docker run --rm --network none -v ./demo:/demo:ro ghcr.io/astral-sh/ruff:0.14.2 check --no-cache /demo
    docker run --rm --network none -v ./infra:/infra:ro -w /infra ghcr.io/opentofu/opentofu:1.12.3 fmt -check
    docker run --rm --network none -v ./dashboards:/dashboards:ro ghcr.io/jqlang/jq:1.8.1 empty {{dash_paths}}
    # The one config vendored verbatim onto every project host; a syntax error
    # here otherwise first surfaces as a crash-looping agent on a client machine.
    # Image ref matches templates/compose.telemetry.yml — keep them in step.
    # Secrets that reached git history. Scans commits, not the working tree, so
    # it sees exactly what is in the repo and never the gitignored .env — a
    # working-tree scan flags .env's real tokens and fails on every dev machine.
    # Needs full history: a shallow CI clone has one commit and passes vacuously.
    docker run --rm --network none -v .:/repo:ro zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f git --redact --no-banner /repo
    docker run --rm --network none -v ./templates/alloy/config.alloy:/etc/alloy/config.alloy:ro -e COMPOSE_PROJECT_NAME=dummy -e ENVIRONMENT=dummy -e PROJECT=dummy -e OTEL_EXPORTER_OTLP_ENDPOINT=https://dummy -e OTLP_AUTH_TOKEN=dummy -e TELEMETRY_EDGE_KEY= grafana/alloy:v1.18.1@sha256:0f4434c92b3e6cdac38bb129b344e1790c246f7b6e2eaffcc16a5fa363240e33 validate /etc/alloy/config.alloy

# Runs against a copy of the sources only: state and tfvars never enter the
# container, which needs network access to fetch the provider.
# Full OpenTofu validation (downloads the provider, so not part of `check`).
infra-validate:
    @d=$(mktemp -d) && cp infra/main.tf infra/.terraform.lock.hcl "$d"/ && docker run --rm --entrypoint sh -v "$d":/src:ro ghcr.io/opentofu/opentofu:1.12.3 -c 'mkdir /work && cp /src/main.tf /src/.terraform.lock.hcl /work && cd /work && tofu init -backend=false -input=false >/dev/null && tofu validate'; rc=$?; rm -rf "$d"; exit $rc

# Format YAML in place (needs yamlfmt on the host; optional).
fmt:
    yamlfmt .

# The tarball is mode 0600 — it contains the Grafana DB and webhook secrets;
# copy it off-host, keep it private. Services are paused during the copy and
# unpaused unconditionally afterwards: `pause` is per-container and can fail
# halfway, so an unpause reached only on success would leave the stack frozen.
# Snapshot all stateful volumes to backups/<timestamp>.tar.gz.
backup: _project-guard
    mkdir -p backups
    -docker compose unpause {{stateful}} 2>/dev/null
    rc=0; docker compose pause {{stateful}} && docker run --rm {{backup_mounts}} -v ./backups:/backups alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b sh -c 'umask 077 && tar czf /backups/monitoring-$(date +%Y%m%d-%H%M%S).tar.gz -C /data .' || rc=$?; docker compose unpause {{stateful}}; exit $rc
    @ls -lh backups/ | tail -1

# The wipe is unrecoverable, so the current state is snapshotted first: if the
# extract dies halfway (full disk, wrong volume set) the volumes are left
# partial, and backups/pre-restore-*.tar.gz is the only way back.
# Restore a backup tarball into the volumes (stops the stack; wipes current state).
restore file: _project-guard
    @[ -f "{{file}}" ] || { echo "error: {{file}} not found" >&2; exit 1; }
    docker run --rm --network none -v {{absolute_path(file)}}:/backup.tar.gz:ro alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b tar tzf /backup.tar.gz > /dev/null
    docker compose down --remove-orphans
    mkdir -p backups
    docker run --rm --network none {{backup_mounts}} -v ./backups:/backups alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b sh -c 'umask 077 && tar czf /backups/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz -C /data .'
    docker run --rm --network none {{backup_mounts}} -v {{absolute_path(file)}}:/backup.tar.gz:ro alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b sh -c 'for d in /data/*; do find "$d" -mindepth 1 -delete; done && tar xzf /backup.tar.gz -C /data'
    @echo "Restored {{file}} — run 'just up' to start the stack."

# `--wait` does the readiness and crash-loop work: it blocks on the grafana and
# prometheus healthchecks in compose.yml and fails if any container exits, so
# there is no poll loop or `ps --status=exited` check to hand-roll here.
# Measured, because it is not obvious: a service with no healthcheck of its own
# (otel-collector, loki, tempo) still fails the wait while it is restarting, so
# a crash-looping collector is caught. It costs the full --wait-timeout to
# report, where the old explicit check failed immediately.
# What it cannot see is provisioning — Grafana answers /api/health long before
# it has read the provisioning dirs, and skips a broken dashboard or a malformed
# alert group silently — so that part is asserted below, on a single loop
# because both land asynchronously.
# Boot an isolated copy of the core stack and assert it provisioned everything.
smoke: (_queue-volume smoke_project)
    {{compose_smoke}} up -d --wait --wait-timeout 120
    @want_dash="$(docker run --rm --network none -v ./dashboards:/dashboards:ro ghcr.io/jqlang/jq:1.8.1 -r .uid {{dash_paths}})"; want_rules=$(grep -h '^ *title:' config/grafana/alerting/*.yaml | wc -l); auth="user = \"admin:${GRAFANA_ADMIN_PASSWORD}\""; n=0; while :; do \
        search=$(printf '%s\n' "$auth" | curl -sf -K - '{{smoke_url}}/api/search?type=dash-db&limit=5000') && rules=$(printf '%s\n' "$auth" | curl -sf -K - {{smoke_url}}/api/v1/provisioning/alert-rules) || { echo "error: Grafana API request failed — wrong GRAFANA_ADMIN_PASSWORD, or Grafana is not answering on {{smoke_url}}" >&2; exit 1; }; \
        have=$(printf '%s' "$search" | docker run --rm -i ghcr.io/jqlang/jq:1.8.1 -r '.[].uid'); got=$(printf '%s' "$rules" | docker run --rm -i ghcr.io/jqlang/jq:1.8.1 length); \
        missing=""; for uid in $want_dash; do printf '%s' "$have" | grep -qx "$uid" || missing="$missing $uid"; done; \
        [ -z "$missing" ] && [ "$want_rules" = "$got" ] && break; \
        n=$((n+3)); [ $n -ge 60 ] && { echo "error: not provisioned after 60s — dashboards missing:${missing:- none}; alert rules $got/$want_rules (a malformed file provisions none of its group). See just smoke-logs" >&2; exit 1; }; \
        sleep 3; \
      done
    @echo "Stack healthy"

# Logs from the smoke stack (its own project, so `just logs` will not show it).
smoke-logs:
    {{compose_smoke}} logs --no-color --tail=200

# Safe: -p scopes it to the smoke project, so it cannot touch a real stack on
# the same host.
# Tear down the smoke stack and its throwaway volumes.
smoke-down:
    {{compose_smoke}} down --remove-orphans --volumes
