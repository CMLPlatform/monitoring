# ADR 0001: Single-host OTLP-native observability stack

Date: 2026-07-03. Status: accepted (records a decision already in production).

## Context

CML runs several long-lived research platforms (RELab and others) that need
their logs, traces, and metrics in one place. The volume is modest — a handful
of services at single-digit requests per second — but one small team maintains
all of it, so whatever we run must stay cheap and auditable.

## Decision

Run one Docker Compose stack on a single host: an OpenTelemetry Collector as
the only ingestion endpoint, fanning out to Loki (logs), Tempo (traces), and
Prometheus (metrics), with Grafana on top. Expose Grafana and the OTLP
endpoints via Cloudflare Tunnel; bind everything else to `127.0.0.1`.

- **OTLP-native:** one endpoint, one protocol. Swap a backend or move it to a
  hosted equivalent without touching any application.
- **Single-host:** one compose file one person can audit and rebuild.
  Distributed ingest (Kubernetes, Mimir, multi-tenant Loki) would add operational
  overhead for no benefit at this volume.
- **Traces as the primary signal:** Tempo's metrics generator derives RED
  metrics and a service graph from spans, so a service that only sends traces
  still gets dashboards and error-rate alerting.

## Alternatives considered

- **Grafana Cloud / hosted SaaS:** less to operate, but a recurring bill,
  data-residency questions for research data, and little institutional
  infrastructure knowledge to show for it.
- **Per-project stacks:** no shared endpoint to maintain, but each project
  duplicates its own storage and Grafana, and cross-project correlation
  becomes impossible.
- **ELK / OpenSearch:** heavier to run and log-centric, with a weaker native
  OTLP and trace-correlation story than the Grafana stack.

## Consequences

- The host is a single point of failure — acceptable, because the monitored
  platforms degrade gracefully when telemetry stops (OTLP export is
  fire-and-forget) and the stack rebuilds from this repo in minutes.
- Local disk bounds retention (30d logs/metrics, 7d traces). The escape hatch,
  reached before any move to distributed ingest, is S3-compatible storage for
  Loki and Tempo — see `compose.storage-s3.yml`.
- Every image is pinned and validated by `just check` in CI, so the stack
  stays reproducible.
