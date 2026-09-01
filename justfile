set dotenv-load

# Stateful services and their volumes, shared by backup/restore. The volume
# names assume the compose project name "monitoring" (see guard in backup).
stateful := "grafana prometheus loki tempo"
backup_mounts := "-v monitoring_grafana_data:/data/grafana -v monitoring_prometheus_data:/data/prometheus -v monitoring_loki_data:/data/loki -v monitoring_tempo_data:/data/tempo"

default:
    @just --list

# The collector's queue volume must be writable by the image's uid 10001, but
# a fresh named volume is root-owned and the image is distroless (no chown at
# startup possible). Idempotent, so every up-path just runs it.
_queue-volume:
    @docker volume create monitoring_otel_queue > /dev/null
    @docker run --rm --network none -v monitoring_otel_queue:/q alpine:3.24 chown 10001:10001 /q

# Core stack (no tunnel; Grafana at http://localhost:3000)
up: _queue-volume
    docker compose up -d

# Core stack + Cloudflare Tunnel (production; needs CLOUDFLARE_TUNNEL_TOKEN).
# Refuses to expose the stack with the documented default credentials.
up-tunnel: _queue-volume
    @[ "${OTLP_AUTH_TOKEN:-}" != "local-dev-token" ] || { echo "error: OTLP_AUTH_TOKEN is still the local default; generate one (openssl rand -hex 32) before exposing ingestion" >&2; exit 1; }
    @[ "${GRAFANA_ADMIN_PASSWORD:-}" != "change-me" ] || { echo "error: GRAFANA_ADMIN_PASSWORD is still the documented default; change it before exposing Grafana" >&2; exit 1; }
    @[ "${GRAFANA_ROOT_URL:-}" != "http://localhost:3000" ] || { echo "error: GRAFANA_ROOT_URL is still the localhost default; set it to the tunnel hostname or every absolute URL Grafana generates breaks" >&2; exit 1; }
    @[ "${GRAFANA_COOKIE_SECURE:-false}" = "true" ] || { echo "error: GRAFANA_COOKIE_SECURE must be true when Grafana is served over HTTPS; set it in .env" >&2; exit 1; }
    @[ -n "${HEARTBEAT_URL:-}" ] || echo "WARNING: HEARTBEAT_URL is empty; the stack goes live without a dead-man's switch" >&2
    @[ -n "${ALERT_WEBHOOK_URL:-}" ] || { echo "error: ALERT_WEBHOOK_URL is empty; every alert would fire into an empty url_file and be dropped. The heartbeat keeps pinging either way, so this failure looks healthy from the outside — set it, or comment out this guard deliberately" >&2; exit 1; }
    docker compose -f compose.yml -f compose.tunnel.yml up -d

down:
    docker compose down --remove-orphans

# Core stack + a demo telemetry source (see compose.demo.yml), then look at
# Grafana: http://localhost:3000
demo: _queue-volume
    docker compose -f compose.yml -f compose.demo.yml up -d --build

# Build the demo image without starting anything. Used by CI to catch a broken
# demo app before it merges.
demo-build:
    docker compose -f compose.yml -f compose.demo.yml build

# Remove only the demo services; the core stack keeps running.
demo-down:
    docker compose -f compose.yml -f compose.demo.yml rm -sf demo-api demo-load

logs service="":
    docker compose -f compose.yml -f compose.demo.yml logs -f {{service}}

ps:
    docker compose -f compose.yml -f compose.demo.yml ps

# Targets the base stack only; demo services are recreated with `just demo`.
restart service:
    docker compose restart {{service}}

pull:
    docker compose pull

# Tail a service's logs as JSON, decoded. Useful before Grafana is set up.
tail service:
    docker compose -f compose.yml -f compose.demo.yml logs -f --no-log-prefix {{service}} | jq -R 'fromjson? // .'

# Validate everything. All validators run in containers — no host installs.
# promtool/otelcol images are read from compose.yml so they can't
# drift from the versions the stack actually runs.
check:
    docker compose config -q
    CLOUDFLARE_TUNNEL_TOKEN=dummy docker compose -f compose.yml -f compose.tunnel.yml config -q
    docker compose -f compose.yml -f compose.demo.yml config -q
    docker run --rm -v ./config/prometheus.yaml:/etc/prometheus/prometheus.yaml:ro -v ./config/alerts:/etc/prometheus/alerts:ro --entrypoint promtool $(docker compose config --images | grep prom/prometheus) check config /etc/prometheus/prometheus.yaml
    docker run --rm -e OTLP_AUTH_TOKEN=dummy -v ./config/otel-collector.yaml:/etc/otelcol/config.yaml:ro $(docker compose config --images | grep opentelemetry-collector) validate --config=/etc/otelcol/config.yaml
    docker run --rm --network none -v ./config/loki.yaml:/etc/loki/loki.yaml:ro $(docker compose config --images | grep grafana/loki) -config.file=/etc/loki/loki.yaml -verify-config
    docker run --rm --network none -v ./config/tempo.yaml:/etc/tempo/tempo.yaml:ro $(docker compose config --images | grep grafana/tempo) -config.file=/etc/tempo/tempo.yaml -config.verify=true
    docker run --rm --network none -v .:/code:ro pipelinecomponents/yamllint:0.35.13 yamllint -d '{extends: relaxed, ignore: [.git/, backups/, infra/.terraform/]}' .
    docker run --rm --network none -v .:/repo:ro -w /repo rhysd/actionlint:1.7.12 -color
    docker run --rm --network none -v ./infra:/infra:ro -w /infra ghcr.io/opentofu/opentofu:1.12.3 fmt -check
    docker run --rm -v ./dashboards:/dashboards:ro ghcr.io/jqlang/jq:1.8.1 empty $(ls dashboards/*.json | sed 's|^dashboards|/dashboards|')

# Full OpenTofu validation (downloads the provider, so not part of `check`).
# Runs against a copy of the sources only: state and tfvars never enter the
# container, which needs network access to fetch the provider.
infra-validate:
    @d=$(mktemp -d) && cp infra/main.tf infra/.terraform.lock.hcl "$d"/ && docker run --rm --entrypoint sh -v "$d":/src:ro ghcr.io/opentofu/opentofu:1.12.3 -c 'mkdir /work && cp /src/main.tf /src/.terraform.lock.hcl /work && cd /work && tofu init -backend=false -input=false >/dev/null && tofu validate'; rc=$?; rm -rf "$d"; exit $rc

# Format YAML in place (needs yamlfmt on the host; optional).
fmt:
    yamlfmt .

# Snapshot all stateful volumes to backups/<timestamp>.tar.gz (mode 0600 —
# it contains the Grafana DB and webhook secrets; copy it off-host, keep it
# private). Services are paused during the copy, and unpaused even if the
# copy fails.
backup:
    @[ -z "${COMPOSE_PROJECT_NAME:-}" ] || { echo "error: COMPOSE_PROJECT_NAME is set; backup expects the monitoring_* volume names" >&2; exit 1; }
    mkdir -p backups
    -docker compose unpause {{stateful}} 2>/dev/null
    docker compose pause {{stateful}} && { docker run --rm {{backup_mounts}} -v ./backups:/backups alpine:3.24 sh -c 'umask 077 && tar czf /backups/monitoring-$(date +%Y%m%d-%H%M%S).tar.gz -C /data .'; rc=$?; docker compose unpause {{stateful}}; exit $rc; }
    @ls -lh backups/ | tail -1

# Restore a backup tarball into the volumes (stops the stack; wipes current state).
restore file:
    @[ -f "{{file}}" ] || { echo "error: {{file}} not found" >&2; exit 1; }
    docker run --rm -v {{absolute_path(file)}}:/backup.tar.gz:ro alpine:3.24 tar tzf /backup.tar.gz > /dev/null
    docker compose down --remove-orphans
    docker run --rm {{backup_mounts}} -v {{absolute_path(file)}}:/backup.tar.gz:ro alpine:3.24 sh -c 'for d in /data/*; do find "$d" -mindepth 1 -delete; done && tar xzf /backup.tar.gz -C /data'
    @echo "Restored {{file}} — run 'just up' to start the stack."

# Boot the core stack, wait until Grafana reports healthy, assert every
# dashboard in dashboards/ actually provisioned (Grafana skips broken ones
# silently), and fail if any service is crash-looping. Used by CI.
smoke: _queue-volume
    docker compose up -d
    n=0; until curl -sf http://localhost:3000/api/health >/dev/null; do n=$((n+3)); [ $n -ge 120 ] && { echo "Grafana not healthy after 120s" >&2; exit 1; }; sleep 3; done
    @for uid in $(docker run --rm --network none -v ./dashboards:/dashboards:ro ghcr.io/jqlang/jq:1.8.1 -r .uid $(ls dashboards/*.json | sed 's|^dashboards|/dashboards|')); do n=0; until curl -sf -u "admin:${GRAFANA_ADMIN_PASSWORD}" "http://localhost:3000/api/dashboards/uid/$uid" >/dev/null; do n=$((n+3)); [ $n -ge 60 ] && { echo "error: dashboard $uid was not provisioned" >&2; exit 1; }; sleep 3; done; done
    @[ -z "$(docker compose ps -q --status=restarting --status=exited)" ] || { echo "error: services not running:" >&2; docker compose ps >&2; exit 1; }
    @echo "Stack healthy"
