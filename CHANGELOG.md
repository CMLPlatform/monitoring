# Changelog

Notable changes to this stack. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/).

## [Unreleased]

Reliability hardening: the stack becomes operable, not just runnable.

### Added

- Bearer-token auth on OTLP ingestion (`OTLP_AUTH_TOKEN`); senders use
  `OTEL_EXPORTER_OTLP_HEADERS`.
- Host self-monitoring: node-exporter, `HostDiskSpaceLow` alert (the
  storage backstop — Loki/Tempo have no total-size cap), **Stack Health**
  dashboard.
- Alert delivery: Alertmanager routes to `ALERT_WEBHOOK_URL`; an
  always-firing `Watchdog` heartbeats to `HEARTBEAT_URL` (dead man's
  switch).
- `just backup` / `just restore` — crash-consistent volume snapshots,
  exercised end-to-end.
- `docs/RUNBOOK.md` and `docs/ONBOARDING.md` with verified telemetry
  templates (zero-code Python, plain OTLP, Loki Docker driver, Grafana
  Alloy).
- `infra/`: OpenTofu for the Cloudflare tunnel, ingress routes, and DNS.

### Changed

- Prometheus storage now bounded by size as well as time
  (`--storage.tsdb.retention.size=15GB`).

### Fixed

- Tempo held at 2.x: a routine bump to 3.0 crash-looped on the 2.x config
  (3.0 is a re-architecture). Dependabot now skips Tempo majors so the
  migration happens deliberately.

## [0.1.0] - 2026-07-03

First tagged release: the stack is runnable, demoable, and validated in CI.

### Added

- `just demo`: one-command demo — an auto-instrumented FastAPI service under
  constant load populates Grafana with correlated traces, metrics, and logs.
- `just check`: validation gate (compose syntax, Prometheus config + alert
  rules, collector config, YAML, workflows, dashboard JSON), all in pinned
  containers. Run by GitHub Actions on every push/PR, plus a `just smoke`
  boot test.
- Provisioned **Service Health (RED)** dashboard driven by Tempo span
  metrics — works for any service that sends traces.
- Prometheus alert rules: target down, OTel export failures, high span
  error rate.
- README: architecture diagram, demo quickstart, screenshot, design
  decisions.
- ADR 0001 recording the single-host OTLP-native architecture, and a
  commented `compose.storage-s3.yml` stub documenting the storage
  scale-out path.

### Changed

- `cloudflared` moved to an optional `compose.tunnel.yml` overlay and pinned
  (was `:latest`); the core stack no longer needs a tunnel token to run.

### Fixed

- OTLP metrics ingestion: Prometheus 3.x renamed the OTLP receiver flag,
  so the collector's metrics export 404ed and OTLP metrics were dropped.

## [0.0.1] - 2026-06-30

Initial stack: OTel Collector → Loki / Tempo / Prometheus → Grafana wired
for cross-signal correlation, exposed via Cloudflare Tunnel, with RELab
dashboards.
