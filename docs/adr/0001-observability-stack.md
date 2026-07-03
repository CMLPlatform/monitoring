# ADR 0001: Single-host OTLP-native observability stack

Date: 2026-07-03. Status: accepted (records a decision already in production).

## Context

CML runs several research platforms (RELab and others) that need logs,
traces, and metrics in one place. Telemetry volume is modest — a handful of
services, single-digit requests per second — but the projects are
long-lived, maintained by a very small team, and must stay cheap and
auditable.

## Decision

Run one Docker Compose stack on a single host: an OpenTelemetry Collector as
the only ingestion endpoint, fanning out to Loki (logs), Tempo (traces), and
Prometheus (metrics), with Grafana on top. Expose Grafana and the OTLP
endpoints via Cloudflare Tunnel; bind everything else to `127.0.0.1`.

- **OTLP-native:** projects configure one endpoint and one protocol.
  Backends can be swapped (or moved to hosted equivalents) without touching
  any application.
- **Single-host:** one compose file is something one person can fully audit
  and rebuild. Distributed ingest (Kubernetes, Mimir, multi-tenant Loki)
  buys nothing at this volume and costs ongoing operational attention.
- **Traces as the primary signal:** Tempo's metrics generator derives RED
  metrics and a service graph from spans, so a service that only sends
  traces still gets dashboards and error-rate alerting.

## Alternatives considered

- **Grafana Cloud / hosted SaaS:** less to operate, but recurring cost,
  data residency questions for research data, and less useful as
  institutional infrastructure knowledge.
- **Per-project stacks:** no shared endpoint to maintain, but duplicates
  storage and Grafana per project and makes cross-project correlation
  impossible.
- **ELK / OpenSearch:** heavier to run, log-centric; weaker native OTLP and
  trace correlation story than the Grafana stack.

## Consequences

- The host is a single point of failure; acceptable because the monitored
  platforms degrade gracefully without telemetry (OTLP export is
  fire-and-forget) and the stack rebuilds from this repo in minutes.
- Local disk bounds retention (30d logs/metrics, 7d traces). The documented
  escape hatch is S3-compatible storage for Loki/Tempo — see
  `compose.storage.s3.yml` — before any move to distributed ingest.
- Everything is pinned and validated by `just check` in CI, so the stack
  stays reproducible.
