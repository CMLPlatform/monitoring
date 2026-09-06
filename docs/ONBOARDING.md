# Sending telemetry from your application

You need an endpoint, a token, and a few naming conventions. Then pick the
template that matches how your application runs. A Python/FastAPI service
needs no code changes.

## The endpoint

| | |
| --- | --- |
| Production (via tunnel) | `https://otel.<domain>`, OTLP **HTTP** (`http/protobuf`) only |
| Private network / same host | `<host>:4317` (gRPC) or `<host>:4318` (HTTP) |
| Auth | `Authorization: Bearer <OTLP_AUTH_TOKEN>` (ask the stack operator) |

The tunnel routes HTTPS to the collector's HTTP receiver only. Set
`OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` when you send through it. gRPC
works on private paths only (VPN, WireGuard, or the same Docker network).
Never expose 4317/4318 directly.

## The conventions

- **`service.name`** is required: one stable name per deployable unit
  (`relab-api`, not `relab-api-prod-2`). Dashboards key on it.
- **`env`** is `prod`, `staging`, or `dev`, set as a resource attribute.
- **Keep labels low-cardinality.** Prometheus turns every distinct label
  value into a series. User IDs, request IDs, and timestamps belong in the
  log line or in span attributes, not in resource attributes or metric labels.
- **Loki indexes only the identity labels**: `service.name`, `department`,
  `project`, `env`, `host.name` (the list is in `config/loki.yaml`). Every
  other attribute is structured metadata. Select the stream first, then
  filter: `{service_name="my-service", env="prod"} | service_instance_id="..."`.

The Service Health dashboard and the error-rate alert read the standard HTTP
server metrics (`http_server_request_duration_seconds`). The
auto-instrumentation below emits them.

## Template 1: Python/FastAPI, zero code changes

```sh
pip install opentelemetry-distro opentelemetry-exporter-otlp opentelemetry-instrumentation-fastapi
```

```sh
export OTEL_SERVICE_NAME=my-service
export OTEL_RESOURCE_ATTRIBUTES=env=prod
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.org
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"
export OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
export OTEL_SEMCONV_STABILITY_OPT_IN=http

opentelemetry-instrument uvicorn app:app --host 0.0.0.0 --port 8000
```

That gives traces, RED metrics, and logs with trace context, with no OTel
code in the app. A working example is this repo's [`demo/`](../demo/) service
plus [`compose.demo.yml`](../compose.demo.yml).

## Template 2: any language, plain OTLP

Every OpenTelemetry SDK reads the same four environment variables:

```sh
OTEL_SERVICE_NAME=my-service
OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.org
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"
OTEL_RESOURCE_ATTRIBUTES=env=prod
```

## Container logs and host metrics

An application cannot report other containers' stdout, host resources, or its
own crash loops. One Grafana Alloy agent per host ships those, over the same
endpoint and token. Run `./bootstrap.sh <project> <env>` on the monitoring
host and follow what it prints. Details are in
[templates/README.md](../templates/README.md).
