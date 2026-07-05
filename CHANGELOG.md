# Changelog

Notable changes to this stack. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/).

## [0.2.0] - 2026-07-05

Makes the stack operable, not just runnable: authentication, self-monitoring,
alert delivery, backups, and infrastructure as code.

### Added

- **Authenticated ingestion**: OTLP now requires a bearer token
  (`OTLP_AUTH_TOKEN`).
- **Self-monitoring**: node-exporter, a **Stack Health** dashboard, and a
  disk-space alert that backstops Loki and Tempo (neither can cap its own
  size).
- **Alert delivery**: Alertmanager posts to any webhook
  (`ALERT_WEBHOOK_URL`), and an always-firing `Watchdog` pings a dead man's
  switch (`HEARTBEAT_URL`) so even a dead host gets noticed.
- **Backup and restore**: `just backup` / `just restore`, tested by wiping
  every volume and recovering.
- **The Cloudflare edge as code**: `infra/` (OpenTofu) manages the tunnel,
  DNS, and an email-PIN Access policy in front of Grafana.
- **Operator and onboarding docs**: a runbook plus copy-paste telemetry
  templates for new projects.
- **Logs Overview dashboard** for OTLP logs, an Active Alerts table on Stack
  Health, and Stack Health as the Grafana home page.

### Changed

- Prometheus storage is now capped by size as well as time (15 GB).
- **Tempo upgraded to 3.0**, migrating off the removed ingester/compactor
  config and verified in place against live traffic.

## [0.1.0] - 2026-07-03

First tagged release: the stack is runnable, demoable, and validated in CI.

### Added

- `just demo`: one-command demo: an auto-instrumented FastAPI service under
  constant load populates Grafana with correlated traces, metrics, and logs.
- `just check`: validation gate (compose syntax, Prometheus config + alert
  rules, collector config, YAML, workflows, dashboard JSON), all in pinned
  containers. Run by GitHub Actions on every push/PR, plus a `just smoke`
  boot test.
- Provisioned **Service Health (RED)** dashboard driven by Tempo span
  metrics: works for any service that sends traces.
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
