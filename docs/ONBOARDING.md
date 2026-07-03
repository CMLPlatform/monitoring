# Sending telemetry from your project

One endpoint, one token, three conventions — then pick the template that
matches how your project runs.

## The endpoint

| | |
| --- | --- |
| Production (via tunnel) | `https://otlp.<domain>` — OTLP **HTTP** (`http/protobuf`) only |
| Private network / same host | `<host>:4317` (gRPC) or `<host>:4318` (HTTP) |
| Auth | `Authorization: Bearer <OTLP_AUTH_TOKEN>` (ask the stack operator) |

The tunnel routes only HTTPS to the collector's HTTP receiver — there is no
public gRPC path, so set `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` when
sending through it. gRPC works only on private paths (VPN/WireGuard, same
Docker network). Never expose 4317/4318 directly.

## The conventions

- **`service.name`** — required; one stable name per deployable unit
  (`relab-api`, not `relab-api-prod-2`). This is what dashboards key on.
- **`env`** — `prod`, `staging`, `dev`, set via resource attributes.
- **Keep label cardinality low** — no user IDs, request IDs, or timestamps
  in resource attributes or log labels; those belong in log lines and span
  attributes, where they're query-time filters.

Any service that sends **traces** automatically gets RED metrics, the
Service Health dashboard, and error-rate alerting — Tempo derives them from
spans. Send traces first; everything else is a bonus.

## Template 1 — Python/FastAPI, zero code changes

```sh
pip install opentelemetry-distro opentelemetry-exporter-otlp opentelemetry-instrumentation-fastapi
```

```sh
export OTEL_SERVICE_NAME=my-service
export OTEL_RESOURCE_ATTRIBUTES=env=prod
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.org
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"
export OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
export OTEL_SEMCONV_STABILITY_OPT_IN=http

opentelemetry-instrument uvicorn app:app --host 0.0.0.0 --port 8000
```

Traces, RED metrics, and logs with trace context — no OTel code in the app.
The living example is this repo's own [`demo/`](../demo/) +
[`compose.demo.yml`](../compose.demo.yml).

## Template 2 — any language, plain OTLP

Every OTel SDK understands the same four env vars:

```sh
OTEL_SERVICE_NAME=my-service
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.org
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"
OTEL_RESOURCE_ATTRIBUTES=env=prod
```

## Template 3 — Docker container logs (Loki driver)

For shipping container stdout/stderr without touching the app. Requires a
Loki push URL, which **this stack does not expose by default** — Loki has no
auth, so a push hostname must first be added to `infra/main.tf` and protected
(Cloudflare Access service token), or reached over a private network path
(VPN/WireGuard). If in doubt, use the OTLP log path above instead.

```sh
# once per host
docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions
```

```yaml
# per service, in compose.yml
logging:
  driver: loki
  options:
    loki-url: ${LOKI_URL}   # e.g. https://logs.example.org/loki/api/v1/push
    loki-external-labels: service={{.Name}},env=prod,host=myhost
```

RELab's `compose.logging.loki.yml` overlay (auto-included when `LOKI_URL`
is set) is the reference implementation of this pattern.

## Template 4 — host or file logs (Grafana Alloy)

For log files outside containers (Promtail is EOL; Alloy is its successor):

```alloy
// alloy/config.alloy
local.file_match "app" {
  path_targets = [{ __path__ = "/var/log/myapp/*.log", service = "myapp", env = "prod", host = "myhost" }]
}

loki.source.file "app" {
  targets    = local.file_match.app.targets
  forward_to = [loki.write.central.receiver]
}

loki.write "central" {
  endpoint {
    url = "https://logs.example.org/loki/api/v1/push"
  }
}
```

```yaml
# compose service
alloy:
  image: grafana/alloy:v1.13.0
  restart: unless-stopped
  command: [ "run", "/etc/alloy/config.alloy" ]
  volumes:
    - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
    - /var/log/myapp:/var/log/myapp:ro
```

Same caveat as Template 3: the Loki push URL needs a protected network path.
