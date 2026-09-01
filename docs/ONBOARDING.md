# Sending telemetry from your project

This stack collects logs, traces, and metrics from CML projects and shows
them side by side in one Grafana. You need an endpoint, a token, and a
couple of naming conventions. Then pick the template that matches how your
project runs; a Python/FastAPI service needs no code changes at all.

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
  value into a series, so user IDs, request IDs, and timestamps do not
  belong in resource attributes or metric labels. Put them in the log line
  or in span attributes: still filterable at query time, without the storage
  blowing up.
- **In Loki, only the identity labels are index labels**: `service.name`,
  `project`, `env`, `host.name` (the authoritative list lives in
  `config/loki.yaml`). Every other attribute, `service.instance.id`
  included, is stored as structured metadata, so a query starts from the
  stream selector and filters after it:
  `{service_name="my-service", env="prod"} | service_instance_id="..."`.

The Service Health dashboard and the error-rate alert key on the standard
HTTP server metrics (`http_server_request_duration_seconds`), which the
auto-instrumentation below emits out of the box. Traces add per-request
drill-down on top.

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

That is the whole integration: traces, RED metrics, and logs carrying their
trace context, with no OTel code in the app. A working example is this
repo's [`demo/`](../demo/) service plus
[`compose.demo.yml`](../compose.demo.yml).

## Template 2 — any language, plain OTLP

Every OpenTelemetry SDK understands the same four environment variables:

```sh
OTEL_SERVICE_NAME=my-service
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.org
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"
OTEL_RESOURCE_ATTRIBUTES=env=prod
```

## Container logs, host metrics, per-container metrics

One Grafana Alloy agent per host ships everything the application cannot report about
itself: other containers' stdout, host resources, container lifecycle. It is vendored
from `templates/`, not written per project, and rides the same OTLP endpoint and token
as Templates 1 and 2 — no second hostname, no second credential.

Run `./bootstrap.sh <project> <env>` on the monitoring host and follow what it prints.
See [templates/README.md](../templates/README.md).
