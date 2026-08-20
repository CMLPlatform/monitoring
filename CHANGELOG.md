# Changelog

Notable changes to this stack. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/).

## [Unreleased]

A hardening pass over the whole stack: buffering that survives a restart,
self-monitoring that covers every service, tighter container defaults, and a
handful of queries that had been quietly measuring the wrong thing.

### Added

- **Durable export queue**: the collector's send queues are file-backed on a
  new `otel_queue` volume, so telemetry buffered during a backend outage
  survives a collector restart. `just up` (and `demo`, `smoke`, `up-tunnel`)
  prepares the volume's ownership; it is deliberately not backed up.
- **Full-stack scraping**: Prometheus now scrapes Grafana, Loki, Tempo, and
  Alertmanager as well, so `TargetDown` covers every service.
- **Per-user Grafana logins**, optional: `GRAFANA_JWT_AUTH` plus
  `CF_ACCESS_TEAM_DOMAIN` make Grafana verify the Cloudflare Access JWT
  instead of everyone sharing the admin password.
- **Memory ceilings** (`mem_limit`) on every service, sized from observed
  usage, so one runaway component cannot OOM the host.
- **Wider validation**: `just check` also verifies the Alertmanager, Loki,
  and Tempo configs and OpenTofu formatting; `just smoke` asserts every
  dashboard actually provisioned; CI additionally runs `just infra-validate`
  and a new `just demo-build`.
- Dependabot now watches the Cloudflare provider in `infra/`, and the runbook
  covers OpenTofu-managed tunnel and Access changes.

### Changed

- **Loki indexes only `service.name`.** Everything else, `service.instance.id`
  included, is structured metadata now — one stream per service instead of one
  per sender restart. Existing streams keep their old labels until they age
  out (30 days).
- **Dashboards are provisioned, not editable**: `dashboards/*.json` is mounted
  read-only and UI saves are off, making the files the source of truth.
- The collector's `memory_limiter` is sized in absolute MiB against the
  container limit, and the queue and retry settings behind the runbook's
  "buffers for five minutes" are pinned rather than inherited from upstream.
- Tempo's metrics generator is capped at 50k active series, so a sender with
  unrouted span names cannot mint Prometheus series without bound.
- Dropped the `relab-api` dashboard: the `$service` picker on Service Health
  and Logs Overview covers it.
- README rewritten for a broader CML audience.
- Image bumps: Grafana 13.1.4, Loki 3.7.6, Tempo 3.0.3, Prometheus 3.13.2,
  the collector 0.156.0, Alertmanager 0.33.1, node-exporter 1.12.1,
  cloudflared 2026.8.2, and the demo's Python dependencies.

### Fixed

- **Trace links from the latency panel**: the Prometheus datasource pointed
  exemplars at a `trace_id` label, but span-metrics exemplars carry `traceID`,
  so clicking a dot resolved to nothing.
- **`HighErrorRate` measured the wrong denominator**: it counted all spans, so
  internal child spans diluted the ratio well below the real request error
  rate. It now filters server spans, matching the Service Health dashboard.
- The demo load generator hit a never-failing endpoint half the time, so the
  advertised one-in-ten error rate showed up as one in twenty.
- The Infrastructure Logs dashboard queried `env` and `service` labels this
  stack does not set, and so was always empty.
- Grafana and the collector now wait for Prometheus to report ready, instead
  of racing it on a cold start.
- The S3 overlay documents the `-config.expand-env=true` that Loki and Tempo
  need before `${...}` in their configs expands at all.

### Security

- `no-new-privileges` on every service; the demo image runs as `nobody`.
- `GRAFANA_COOKIE_SECURE` marks the session cookie Secure (with strict
  SameSite), and `just up-tunnel` refuses to expose the stack without it, a
  non-localhost `GRAFANA_ROOT_URL`, and non-default credentials.
- GitHub Actions are pinned to commit SHAs, and `just infra-validate` runs
  against a copy of the sources so state and tfvars never enter the container.

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
