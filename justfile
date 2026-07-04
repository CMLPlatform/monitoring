set dotenv-load

# Stateful services and their volumes, shared by backup/restore. The volume
# names assume the compose project name "monitoring" (see guard in backup).
stateful := "grafana prometheus loki tempo alertmanager"
backup_mounts := "-v monitoring_grafana_data:/data/grafana -v monitoring_prometheus_data:/data/prometheus -v monitoring_loki_data:/data/loki -v monitoring_tempo_data:/data/tempo -v monitoring_alertmanager_data:/data/alertmanager"

default:
    @just --list

# Core stack (no tunnel; Grafana at http://localhost:3000)
up:
    docker compose up -d

# Core stack + Cloudflare Tunnel (production; needs CLOUDFLARE_TUNNEL_TOKEN).
# Refuses to expose the stack with the documented default credentials.
up-tunnel:
    @[ "${OTLP_AUTH_TOKEN:-}" != "local-dev-token" ] || { echo "error: OTLP_AUTH_TOKEN is still the local default; generate one (openssl rand -hex 32) before exposing ingestion" >&2; exit 1; }
    @[ "${GRAFANA_ADMIN_PASSWORD:-}" != "change-me" ] || { echo "error: GRAFANA_ADMIN_PASSWORD is still the documented default; change it before exposing Grafana" >&2; exit 1; }
    docker compose -f compose.yml -f compose.tunnel.yml up -d

down:
    docker compose down --remove-orphans

# Core stack + a demo telemetry source (see compose.demo.yml), then look at
# Grafana: http://localhost:3000
demo:
    docker compose -f compose.yml -f compose.demo.yml up -d --build

# Remove only the demo services; the core stack keeps running.
demo-down:
    docker compose -f compose.yml -f compose.demo.yml rm -sf demo-api demo-load

logs service="":
    docker compose logs -f {{service}}

ps:
    docker compose ps

restart service:
    docker compose restart {{service}}

pull:
    docker compose pull

# Tail a service's logs as JSON, decoded. Useful before Grafana is set up.
tail service:
    docker compose logs -f --no-log-prefix {{service}} | jq -R 'fromjson? // .'

# Validate everything. All validators run in containers — no host installs.
# promtool/otelcol/amtool images are read from compose.yml so they can't
# drift from the versions the stack actually runs.
check:
    docker compose config -q
    CLOUDFLARE_TUNNEL_TOKEN=dummy docker compose -f compose.yml -f compose.tunnel.yml config -q
    docker compose -f compose.yml -f compose.demo.yml config -q
    docker run --rm -v ./config/prometheus.yaml:/etc/prometheus/prometheus.yaml:ro -v ./config/alerts:/etc/prometheus/alerts:ro --entrypoint promtool $(docker compose config --images | grep prom/prometheus) check config /etc/prometheus/prometheus.yaml
    docker run --rm -e OTLP_AUTH_TOKEN=dummy -v ./config/otel-collector.yaml:/etc/otelcol/config.yaml:ro $(docker compose config --images | grep opentelemetry-collector) validate --config=/etc/otelcol/config.yaml
    docker run --rm -v ./config/alertmanager.yaml:/etc/alertmanager/alertmanager.yaml:ro --entrypoint /bin/amtool $(docker compose config --images | grep prom/alertmanager) check-config /etc/alertmanager/alertmanager.yaml
    docker run --rm -v .:/code:ro pipelinecomponents/yamllint:0.35.13 yamllint -d '{extends: relaxed, ignore: [.git/, backups/, infra/.terraform/]}' .
    docker run --rm -v .:/repo:ro -w /repo rhysd/actionlint:1.7.12 -color
    docker run --rm -v ./infra:/infra:ro -w /infra ghcr.io/opentofu/opentofu:1.12.3 fmt -check
    docker run --rm -v ./dashboards:/dashboards:ro ghcr.io/jqlang/jq:1.8.1 empty $(ls dashboards/*.json | sed 's|^dashboards|/dashboards|')

# Full OpenTofu validation (downloads the provider, so not part of `check`).
infra-validate:
    docker run --rm --entrypoint sh -v ./infra:/infra -w /infra ghcr.io/opentofu/opentofu:1.12.3 -c 'tofu init -backend=false -input=false >/dev/null && tofu validate'

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

# Boot the core stack, wait until Grafana reports healthy, and fail if any
# service is crash-looping. Used by CI.
smoke:
    docker compose up -d
    n=0; until curl -sf http://localhost:3000/api/health >/dev/null; do n=$((n+3)); [ $n -ge 120 ] && { echo "Grafana not healthy after 120s" >&2; exit 1; }; sleep 3; done
    @[ -z "$(docker compose ps -q --status=restarting --status=exited)" ] || { echo "error: services not running:" >&2; docker compose ps >&2; exit 1; }
    @echo "Stack healthy"
