# Observability stack

Central Grafana + Loki + Tempo + Prometheus + OTel Collector, wired together
with logs ↔ traces ↔ metrics correlation. Meant to run on one host and
receive telemetry from multiple projects over OTLP.

```mermaid
flowchart LR
    apps["Project apps<br/>(OTLP gRPC 4317 / HTTP 4318)"] --> otel["OTel Collector<br/>(ingestion gateway)"]
    otel -- logs --> loki[Loki]
    otel -- traces --> tempo[Tempo]
    otel -- metrics --> prom[Prometheus]
    tempo -- "span metrics (RED)" --> prom
    loki --> grafana[Grafana]
    tempo --> grafana
    prom --> grafana
    grafana --- cf["Cloudflare Tunnel<br/>(optional overlay)"]
```

## Demo: see it work in one command

```sh
cp .env.example .env
just demo
```

This starts the full stack plus a small auto-instrumented FastAPI service
under constant load (`compose.demo.yml`). Give it a minute, then open
Grafana at <http://localhost:3000> (admin / change-me):

- **Dashboards → Service Health (RED)** — request rate, error rate, and
  latency for the demo service. Latency dots are exemplars: click one to
  open that exact trace in Tempo.
- **Explore → Loki** — `{service_name="demo-api"}`; expand an error line
  and follow its `trace_id` to the trace.
- **Alerting → Alert rules** — stack-health and error-rate rules,
  evaluated by Prometheus.

![Service Health (RED) dashboard](docs/img/service-health.png)

Tear it down with `just demo-down`.

## Layout

```
compose.yml             # core services
compose.tunnel.yml      # production overlay: Cloudflare Tunnel
compose.demo.yml        # demo overlay: sample telemetry source
demo/                   # the demo FastAPI service
config/
  otel-collector.yaml   # ingestion gateway (OTLP in → Loki/Tempo/Prometheus out)
  loki.yaml             # logs
  tempo.yaml            # traces
  prometheus.yaml       # metrics
  alerts/               # Prometheus alert rules
  grafana/              # provisioned datasources + dashboard loader
dashboards/             # drop JSON dashboards here; Grafana auto-loads them
```

## Run

```sh
cp .env.example .env    # set GRAFANA_ADMIN_PASSWORD
just up                 # core stack, local only
just up-tunnel          # core stack + Cloudflare Tunnel (needs CLOUDFLARE_TUNNEL_TOKEN)
```

Grafana: <http://localhost:3000> (admin / whatever you set).

`just check` validates everything (compose files, Prometheus config and
alert rules, collector config, YAML, workflows, dashboard JSON) in pinned
containers — no host installs. CI runs the same command on every push and
PR, plus a smoke test that boots the stack and waits for Grafana to report
healthy.

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

## Alerting

Prometheus evaluates the rules in `config/alerts/` (target down, OTel
export failures, >5% span error rate) and Grafana surfaces them under
Alerting → Alert rules. There is deliberately no Alertmanager: on a
single-host stack, another service buys routing complexity before anyone
needs it. Add one (or a Grafana contact point) when alerts must page
someone.

## Storage

Everything persists to local Docker volumes (`loki_data`, `tempo_data`,
`prometheus_data`, `grafana_data`). Swap Loki / Tempo storage to S3-compatible
(Backblaze B2, Cloudflare R2, Hetzner, MinIO) when you outgrow local disk.

## Design decisions

Everything enters through **one OTLP gateway** (the collector), so projects
configure a single endpoint and the backends can be swapped without touching
any app. The stack is **single-host by design** — CML's telemetry volume
doesn't justify distributed ingest, and one compose file is auditable — with
a documented scale-out path (S3-backed Loki/Tempo above) when it stops
fitting. Logs keep **label cardinality low** (`service`, `env`, `host` only;
everything else is query-time filtering) because high-cardinality labels are
how Loki installs fall over. RED metrics are **derived from traces** by
Tempo's metrics generator, so any service that sends traces gets the
Service Health dashboard for free, instrumented or not.
