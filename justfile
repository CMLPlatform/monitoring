set dotenv-load

default:
    @just --list

# Core stack (no tunnel; Grafana at http://localhost:3000)
up:
    docker compose up -d

# Core stack + Cloudflare Tunnel (production; needs CLOUDFLARE_TUNNEL_TOKEN)
up-tunnel:
    docker compose -f compose.yml -f compose.tunnel.yml up -d

down:
    docker compose down --remove-orphans

# Core stack + a demo telemetry source (see compose.demo.yml), then look at
# Grafana: http://localhost:3000
demo:
    docker compose -f compose.yml -f compose.demo.yml up -d --build

demo-down:
    docker compose -f compose.yml -f compose.demo.yml down

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
check:
    docker compose config -q
    CLOUDFLARE_TUNNEL_TOKEN=dummy docker compose -f compose.yml -f compose.tunnel.yml config -q
    docker compose -f compose.yml -f compose.demo.yml config -q
    docker run --rm -v ./config/prometheus.yaml:/etc/prometheus/prometheus.yaml:ro -v ./config/alerts:/etc/prometheus/alerts:ro --entrypoint promtool prom/prometheus:v3.13.0 check config /etc/prometheus/prometheus.yaml
    docker run --rm -e OTLP_AUTH_TOKEN=dummy -v ./config/otel-collector.yaml:/etc/otelcol/config.yaml:ro otel/opentelemetry-collector-contrib:0.155.0 validate --config=/etc/otelcol/config.yaml
    docker run --rm -v ./config/alertmanager.yaml:/etc/alertmanager/alertmanager.yaml:ro --entrypoint /bin/amtool prom/alertmanager:v0.33.0 check-config /etc/alertmanager/alertmanager.yaml
    docker run --rm -v .:/code:ro pipelinecomponents/yamllint:0.35.13 yamllint -d relaxed .
    docker run --rm -v .:/repo:ro -w /repo rhysd/actionlint:1.7.12 -color
    jq empty dashboards/*.json

# Format YAML in place (needs yamlfmt on the host; optional).
fmt:
    yamlfmt .

# Snapshot all stateful volumes to backups/<timestamp>.tar.gz. Services are
# paused during the copy (seconds), so the backup is crash-consistent.
backup:
    mkdir -p backups
    -docker compose unpause grafana prometheus loki tempo alertmanager 2>/dev/null
    docker compose pause grafana prometheus loki tempo alertmanager
    docker run --rm -v monitoring_grafana_data:/data/grafana -v monitoring_prometheus_data:/data/prometheus -v monitoring_loki_data:/data/loki -v monitoring_tempo_data:/data/tempo -v monitoring_alertmanager_data:/data/alertmanager -v ./backups:/backups alpine:3.24 tar czf /backups/monitoring-$(date +%Y%m%d-%H%M%S).tar.gz -C /data .
    docker compose unpause grafana prometheus loki tempo alertmanager
    @ls -lh backups/ | tail -1

# Restore a backup tarball into the volumes (stack must be down; wipes current state).
restore file:
    docker compose down --remove-orphans
    docker run --rm -v monitoring_grafana_data:/data/grafana -v monitoring_prometheus_data:/data/prometheus -v monitoring_loki_data:/data/loki -v monitoring_tempo_data:/data/tempo -v monitoring_alertmanager_data:/data/alertmanager -v ./{{file}}:/backup.tar.gz:ro alpine:3.24 sh -c 'for d in /data/*; do find "$d" -mindepth 1 -delete; done && tar xzf /backup.tar.gz -C /data'
    @echo "Restored {{file}} — run 'just up' to start the stack."

# Boot the core stack and wait until Grafana reports healthy. Used by CI.
smoke:
    docker compose up -d
    n=0; until curl -sf http://localhost:3000/api/health >/dev/null; do n=$((n+3)); [ $n -ge 120 ] && { echo "Grafana not healthy after 120s" >&2; exit 1; }; sleep 3; done
    @echo "Grafana healthy"
