# Observability stack

Central Grafana + Loki + Tempo + Prometheus + OTel Collector, wired together
with logs ↔ traces ↔ metrics correlation. Meant to run on one host and
receive telemetry from multiple projects over OTLP.

## Layout

```
compose.yml             # all services
config/
  otel-collector.yaml   # ingestion gateway (OTLP in → Loki/Tempo/Prometheus out)
  loki.yaml             # logs
  tempo.yaml            # traces
  prometheus.yaml       # metrics
  grafana/              # provisioned datasources + dashboard loader
dashboards/             # drop JSON dashboards here; Grafana auto-loads them
```

## Run

```sh
cp .env.example .env    # set GRAFANA_ADMIN_PASSWORD
just up
```

Grafana: <http://localhost:3000> (admin / whatever you set).

## Sending telemetry from a project

### Traces + metrics (OTLP)

Point your app (or its local OTel Collector) at this host's OTLP endpoints:

- gRPC: `<host>:4317`
- HTTP: `<host>:4318`

Do **not** publish those ports to the public internet. Expose the monitoring
host via Cloudflare Tunnel, Tailscale, or WireGuard — the compose file binds
them to `127.0.0.1` to make that the obvious path.

### Logs (Loki Docker driver)

Container stdout/stderr is best shipped directly by the Docker daemon using
the Loki log driver plugin. On each project host:

```sh
# 1. Install the driver plugin (once per host)
docker plugin install grafana/loki-docker-driver:latest \
  --alias loki --grant-all-permissions

# 2. Set LOKI_URL in the host's .env, e.g.
#    LOKI_URL=https://logs.example.org/loki/api/v1/push
```

How the project wires it up is project-specific. The RELab repo, for
example, uses an optional overlay (`compose.logging.loki.yml`) that the
justfile auto-includes when `LOKI_URL` is set — hosts without Loki keep
Docker's default json-file driver. Other projects can do the equivalent:
set the daemon-wide `log-driver` in `/etc/docker/daemon.json`, or add a
per-service `logging:` block.

Logs carry labels for `service`, `env`, and `host` so you can filter in
Grafana. Keep label cardinality low — don't add `user_id`, `request_id`,
etc. as labels; use LogQL filters for those.

## Storage

Everything persists to local Docker volumes (`loki_data`, `tempo_data`,
`prometheus_data`, `grafana_data`). Swap Loki / Tempo storage to S3-compatible
(Backblaze B2, Cloudflare R2, Hetzner, MinIO) when you outgrow local disk.
