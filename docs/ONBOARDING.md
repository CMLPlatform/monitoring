# Connecting a Project

Choose your project type to find the right onboarding recipe:

| Project Type | What it monitors | Setup Time | Recipe |
| --- | --- | --- | --- |
| **Python / FastAPI Web App** | Traces, RED metrics, error logs | 5 minutes | [Template 1: Web Services](#template-1-python--fastapi-services) |
| **CLI / Batch Script / Other Lang** | Custom traces, metrics, logs | 5 minutes | [Template 2: General Applications](#template-2-general-applications-any-language) |
| **Static Website / Portal** | Availability, HTTP 2xx latency, TLS expiry | 1 minute | [Template 3: Static & Edge Sites](#template-3-static--edge-websites-outside-in) |
| **Browser Frontend / Web App** | Core Web Vitals (LCP, CLS), client errors | 2 minutes | [Template 4: Browser RUM](#template-4-browser-real-user-monitoring-rum) |
| **Entire VM or Server Host** | Host CPU/RAM/Disk, container lifecycle, stdout | 10 minutes | [Host Agent: Grafana Alloy](#host-agent-container-logs-and-host-metrics) |

---

## Endpoint and Credentials

Request the active endpoint URL and ingest token from the monitoring administrator:

| Path | Ingestion Target | Protocol | Notes |
| --- | --- | --- | --- |
| **Production (via tunnel)** | `https://otel.<domain>` | OTLP HTTP (`http/protobuf`) | Uses Cloudflare Tunnel |
| **Private network / same host** | `<host>:4317` (gRPC) or `<host>:4318` (HTTP) | OTLP gRPC or HTTP | Direct internal networking |
| **Authentication** | `Authorization: Bearer <token>` | Header | Enforced at gateway |

> [!WARNING]
> Never expose ports 4317 or 4318 directly to the public internet. The compose stack binds them to `127.0.0.1`.

---

## Required Naming Conventions

Every signal requires three identity labels to route correctly and avoid alerting rules tripping:

1. **`service.name`**: One stable identifier per deployable unit (e.g. `r9lab-api`). Dashboards filter on this name.
2. **`project`**: The project identifier registered with the hub (e.g. `r9lab`).
3. **`env`**: Environment tier: `prod`, `staging`, or `dev`.

Keep metric labels low-cardinality. Put user identifiers, request IDs, and query parameters inside log messages or span attributes, never in resource attributes or metric labels.

---

## Template 1: Python / FastAPI Services

Auto-instrument a Python application with zero code changes.

### 1. Install dependencies

```sh
pip install opentelemetry-distro opentelemetry-exporter-otlp opentelemetry-instrumentation-fastapi
```

### 2. Export environment variables

```sh
export OTEL_SERVICE_NAME=my-service
export OTEL_RESOURCE_ATTRIBUTES=project=my-project,env=prod
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.org
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"
export OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
export OTEL_SEMCONV_STABILITY_OPT_IN=http
```

### 3. Run the service

```sh
opentelemetry-instrument uvicorn app:app --host 0.0.0.0 --port 8000
```

This exports traces, RED metrics, and correlated logs to the hub. A working reference is available in [`demo/`](../demo/) and [`compose.demo.yml`](../compose.demo.yml).

---

## Template 2: General Applications (Any Language)

Any standard OpenTelemetry SDK reads these four environment variables:

```sh
OTEL_SERVICE_NAME=my-service
OTEL_RESOURCE_ATTRIBUTES=project=my-project,env=prod
OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.org
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"
```

Configure your application SDK to use standard OTLP/HTTP export.

---

## Template 3: Static & Edge Websites (Outside-In)

For documentation portals, static pages (GitHub Pages, Cloudflare Pages), or edge sites without a backend server, register an external probe:

```sh
just probe-add <project> <env> <url> [tier]
```

Example for a public gallery:

```sh
just probe-add cml-gallery prod https://cmlplatform.github.io/cml-gallery/ edge
```

Prometheus reloads `config/targets/probes.yaml` automatically without a restart. The blackbox exporter probes HTTP 2xx availability, response latency, and TLS certificate expiration. Downtime trips the `BlackboxProbeFailed` alert without false telemetry warnings.

---

## Template 4: Browser Real User Monitoring (RUM)

For browser performance and error tracking, first ask the hub administrator for
a restricted public ingestion proxy. It must keep the collector bearer private,
fix the project's identity, and limit payload size and request rate. Leave RUM
disabled until that ingress and the collection agreement are ready.

Then configure the snippet from [`templates/web/rum.html`](../templates/web/rum.html):

```html
<script>
  window.__OTEL_ENDPOINT__ = "https://rum.example.org";
  window.__OTEL_PROJECT__ = "my-project";
  window.__OTEL_SERVICE__ = "my-web";
  window.__OTEL_ENV__ = "prod";
</script>
<!-- Paste contents of templates/web/rum.html here -->
```

What it captures:

- **Core Web Vitals:** Largest Contentful Paint (LCP) and Cumulative Layout Shift (CLS).
- **Client Exceptions:** Unhandled `window.onerror` exceptions and unhandled promise rejections.
- **Log Streams:** Emits structured OTLP/HTTP JSON (`/v1/logs`) indexed into Loki.

Never put the shared collector token in public HTML. CORS does not protect that
credential. See [`templates/web/README.md`](../templates/web/README.md) for the ingress requirements.

---

## Host Agent: Container Logs and Host Metrics

Applications cannot monitor host CPU, memory, disk saturation, or container crash loops.

A shared Grafana Alloy agent runs on each project host to collect system metrics and Docker logs. Run `./bootstrap.sh <project> <env>` on the monitoring host to generate the project configuration and alerts.

Complete host agent deployment steps are documented in [templates/README.md](../templates/README.md).
