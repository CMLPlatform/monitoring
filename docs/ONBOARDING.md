# Sending telemetry from your project

This stack collects logs, traces, and metrics from CML projects and shows
them side by side in one Grafana. Getting your project in takes an
endpoint, a token, and a couple of naming conventions. Then pick the
template that matches how your project runs — if it's a Python/FastAPI
service, Template 1 needs no code changes at all.

## The endpoint

| | |
| --- | --- |
| Production (via tunnel) | `https://otlp.<domain>` — OTLP **HTTP** (`http/protobuf`) only |
| Private network / same host | `<host>:4317` (gRPC) or `<host>:4318` (HTTP) |
| Auth | `Authorization: Bearer <OTLP_AUTH_TOKEN>` (ask the stack operator) |

The tunnel only routes HTTPS to the collector's HTTP receiver; there is no
public gRPC path. When sending through it, set
`OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`. gRPC works on private paths
only (VPN/WireGuard, or the same Docker network). Never expose 4317/4318
directly.

## The conventions

- **`service.name`** is required: one stable name per deployable unit
  (`relab-api`, not `relab-api-prod-2`). Dashboards key on it.
- **`env`** is `prod`, `staging`, or `dev`, set as a resource attribute.
- **Keep labels low-cardinality.** Prometheus turns every distinct label
  value into a series. User IDs, request IDs, and timestamps therefore
  don't belong in resource attributes or metric labels. Put them in the log
  line or in span attributes instead — you can still filter on them at
  query time, without the storage blowing up.
- **In Loki, `service.name` is the only index label.** Every other
  attribute, `service.instance.id` included, is stored as structured
  metadata, so a query starts from the stream selector and filters after
  it: `{service_name="my-service"} | env="prod"`. Streams written before
  this change keep their old labels until they age out after 30 days.

Traces are the most valuable signal to send. Tempo derives request-rate,
error-rate, and duration ("RED") metrics from them, so a service that
sends only traces already gets the Service Health dashboard and error
alerting. Start with traces; everything else is a bonus.

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

That's the whole integration: traces, RED metrics, and logs that carry
their trace context, without a line of OTel code in the app. The working
example is this repo's own [`demo/`](../demo/) service plus
[`compose.demo.yml`](../compose.demo.yml).

## Template 2 — any language, plain OTLP

Every OpenTelemetry SDK understands the same four environment variables:

```sh
OTEL_SERVICE_NAME=my-service
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.org
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"
OTEL_RESOURCE_ATTRIBUTES=env=prod
```

## Template 3 — Docker container logs (Loki driver)

This ships container stdout/stderr without touching the app. It needs a
Loki push URL, which **this stack does not expose by default**: Loki has
no authentication of its own, so a push hostname must first be added to
`infra/main.tf` and protected with a Cloudflare Access service token, or
reached over a private network path (VPN/WireGuard). If in doubt, use the
OTLP log path from Templates 1–2 instead.

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

RELab's `compose.logging.loki.yml` overlay, auto-included when `LOKI_URL`
is set, is the reference implementation of this pattern.

## Template 4 — host or file logs (Grafana Alloy)

For log files that live outside containers. (Promtail is end-of-life;
Alloy is its successor.)

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

The same caveat as Template 3 applies: the Loki push URL needs a protected
network path.
