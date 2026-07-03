# Changelog

Notable changes to this stack. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/).

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
