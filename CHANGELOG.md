# Changelog

Notable changes to this stack. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

A hardening pass over the whole stack: buffering that survives a restart,
self-monitoring that covers every service, tighter container defaults, and
queries that had been measuring the wrong thing.

### Added

- **Durable export queue**: the collector's send queues are file-backed on a
  new `otel_queue` volume, so telemetry buffered during a backend outage
  survives a collector restart. `just up` (and `demo`, `smoke`) prepares the
  volume's ownership. `just backup` skips the volume, whose contents are
  worthless by the time anyone restores.
- **Full-stack scraping**: Prometheus now scrapes Grafana, Loki, and Tempo as
  well, so `TargetDown` covers every service.
- **Early storage warnings**: `HostDiskFilling` (a filesystem is full within
  3 days at the current rate) and `PrometheusCardinalityHigh` (over 100k
  active series) fire while there is still time, ahead of the 80% backstop.
- **Per-user Grafana logins**, optional: `GRAFANA_JWT_AUTH` plus
  `CF_ACCESS_TEAM_DOMAIN` and `CF_ACCESS_AUD` make Grafana verify the
  Cloudflare Access JWT (pinned to this app's `aud` tag, with both values
  enforced by the exposure guards) instead of everyone sharing the admin
  password.
- **Memory ceilings** (`mem_limit`) on every service, sized from observed
  usage, so one runaway component cannot OOM the host. The spoke Alloy agent
  gains a matching in-pipeline memory limiter, so a long hub outage sheds load
  instead of OOM-killing the agent and its loss counters with it.
- **Tighter container defaults**: every service drops all capabilities,
  node-exporter (which holds `pid: host` and the host filesystem) runs
  read-only with a pids limit, and the hub images are digest-pinned like the
  client templates. The tunnel token reaches cloudflared via environment, not
  argv.
- **Wider validation**: `just check` also verifies the Loki and Tempo configs,
  the vendored Alloy config, shell scripts, the demo app's Python, OpenTofu
  formatting, the datasource uids dashboards reference, the alert templates
  `bootstrap.sh` renders, and git history for secrets; CI also runs
  `just infra-validate`; `lint` also enforces yamlfmt and ruff formatting.
  `check` splits into `lint` (static) and `validate` (the stack's own images);
  CI runs the two on separate jobs so a lint failure never waits on the stack
  images, on pull requests only (`main` requires one), skipping prose-only
  changes; `infra/` validates on its own workflow when `infra/` changes. `just hooks` installs git hooks via prek: gitleaks on the staged
  diff and `lint` at commit, a Conventional Commits check on the message,
  `validate` at push, `infra-validate` at push when `infra/` changed.
- **`just smoke` boots the production shape and asserts the data paths**: JWT
  auth on with a forged Access token refused, dashboards and alert rules
  compared uid for uid (not by count) with no rule paused, contact points
  checked against the exact URLs given, every scrape target up, and a metric
  and a log round-tripped through the collector into Prometheus and Loki with
  the promoted `project`/`env`/`department` labels. The assertions moved to
  `scripts/smoke.sh` (functions, shellcheck). `just restore-check` rehearses
  backup and restore on the smoke volumes. `just demo-build` is gone: the
  demo is a local fixture (`just demo`), not a CI step.
- `just fmt` runs yamlfmt in a container like every other tool.
- **Isolated smoke and demo**: each runs under its own compose project and
  Grafana port (`compose.sandbox.yml`), so neither can adopt or recreate a
  stack already running on the host.
- `bootstrap.sh` refuses to run from a release tag that lacks `templates/`
  and prints `sha256sum -c` lines for the files it tells a project host to
  vendor.
- Dependabot now watches the Cloudflare provider in `infra/`, and the runbook
  covers OpenTofu-managed tunnel and Access changes.
- **`infra/generate-imports.sh`**: emits OpenTofu `import` blocks for the edge
  built by hand in the Zero Trust dashboard. Without it the first plan against
  an empty state reads "create" for objects already serving traffic, and
  applying it mints a second tunnel and a duplicate Access app.

### Changed

- **Ingestion hostname is `otel.<domain>`**, not `otlp.<domain>`: one
  department-wide name for machine telemetry alongside `grafana.<domain>` for
  humans. Every spoke's `OTEL_EXPORTER_OTLP_ENDPOINT` and any edge rule matching
  the old host have to follow.
- **`department` on every signal**: the gateway collector stamps it from
  `DEPARTMENT` in `.env` and Prometheus and Loki carry it as an identity label.
  It is set at the hub rather than by the sender, so a spoke cannot ship
  telemetry attributed to someone else.
- **Overlays are host config now**: `COMPOSE_FILE` in `.env` names the compose
  file set, and every recipe (`up`, `logs`, `ps`, `backup`) acts on that same
  set. `just up-tunnel` is gone; its exposure guards run automatically
  whenever the tunnel overlay is active.
- **Loki indexes only the identity labels** (`service.name`, `department`,
  `project`, `env`, `host.name`; the authoritative list lives in
  `config/loki.yaml`). Everything else, `service.instance.id` included, is
  structured metadata now: one stream per service instead of one per sender
  restart. Existing streams keep their old labels until they age out (30 days).
- **Dashboards are provisioned, not editable**: `dashboards/*.json` is mounted
  read-only and UI saves are off, making the files the source of truth.
- The collector's `memory_limiter` is sized in absolute MiB against the
  container limit, and the queue and retry settings behind the runbook's
  "buffers for five minutes" are pinned rather than inherited from upstream.
- **Tempo's metrics generator is removed**: RED comes from the applications'
  own OTLP metrics now (ADR 0002), so Tempo stores traces and nothing else.
- Dropped the `relab-api` dashboard: the `$service` picker on Service Health
  and Logs covers it.
- README rewritten for a broader CML audience.
- Image bumps: Grafana 13.1.4, Loki 3.7.6, Tempo 3.0.3, Prometheus 3.13.2,
  the collector 0.156.0, node-exporter 1.12.1, cloudflared 2026.8.2, and the
  demo's Python dependencies.

### Removed

- **Alertmanager**: alerting is Grafana-managed now (ADR 0002). Rules are
  provisioned from `config/grafana/alerting/`, and delivery still posts to
  `ALERT_WEBHOOK_URL`. Its `alertmanager_data` volume is left behind on an
  upgraded host; the runbook says when to remove it.
- The commented `compose.storage-s3.yml` stub: the S3 escape hatch lives as
  an appendix of ADR 0001 instead.

### Fixed

- `just backup` fails (instead of exiting 0) when the unpause after the copy
  fails and the stack is left paused. `just lint`'s exposure-guard self-test
  lost the status of its positive half; a guard that rejected every valid
  `.env` passed CI. The smoke provisioning check could pass with an empty
  dashboard list if reading the uids failed. `bootstrap.sh` printed the hash
  of empty input for a template missing from the tag, and re-reads its rule
  from Grafana after the restart instead of trusting the restart.
  `infra/generate-imports.sh` reported a failed DNS API call as "no record".
- **Spoke overlay declared no `egress` network**: `compose.telemetry.yml`
  joined it without defining it, so the documented `up -d` failed on any host
  whose own compose file did not happen to name one. `just check` now renders
  both spoke overlays.
- **GPU dashboard host picker keyed on `instance`**, which is the same
  in-container address on every host; it uses `host_name` like the rest.
  Dashboard variables refresh on load, not on every 30s tick.
- **Access app import id**: `generate-imports.sh` emitted it without the
  `accounts/` scope the 5.x provider requires.
- **`just smoke` proves delivery and the data path**: contact points must be
  expanded (no literal `$VAR`), and one OTLP log through the collector's
  bearer auth must come back out of Loki carrying the `department` label.
- **Trace links from the latency panel**: the Prometheus datasource pointed
  exemplars at a `trace_id` label, but span-metrics exemplars carry `traceID`,
  so clicking a dot resolved to nothing.
- **`HighErrorRate` measured the wrong denominator**: it counted all spans, so
  internal child spans diluted the ratio well below the real request error
  rate. It now reads the applications' HTTP server metrics, matching the
  Service Health dashboard.
- The demo load generator hit a never-failing endpoint half the time, so the
  advertised one-in-ten error rate showed up as one in twenty.
- The Infrastructure Logs dashboard queried `env` and `service` labels this
  stack does not set, and so was always empty.
- Grafana and the collector now wait for Prometheus to report ready, instead
  of racing it on a cold start.
- The S3 overlay documents the `-config.expand-env=true` that Loki and Tempo
  need before `${...}` in their configs expands at all.
- **`HighErrorRate` merged environments**: aggregating by job alone let a
  healthy prod service dilute a broken staging one sharing the job name below
  the threshold. It now keys on job, project and env like the other
  multi-tenant rules. `HostDiskSpaceLow` says whose disk is filling.
- With `GRAFANA_JWT_AUTH=true` but no team domain set, Grafana fetched its
  JWT signing keys from a placeholder `cloudflareaccess.com` subdomain any
  Cloudflare customer could claim; the fallback is gone and the guards refuse
  to start without the real values.

### Security

- `no-new-privileges` on every service; the demo image runs as `nobody`.
- `GRAFANA_COOKIE_SECURE` marks the session cookie Secure (with strict
  SameSite), and `just up` with the tunnel overlay refuses to expose the stack
  without it, an `https://` `GRAFANA_ROOT_URL`, and non-default credentials.
  `just check` runs the guards both ways, so a guard that silently accepts a
  default fails CI rather than the production start.
- Loki, Tempo, Prometheus and node-exporter sit on an internal `backend`
  network only Grafana and the collector join. cloudflared stays on `default`,
  so an ingress edited in the Cloudflare dashboard cannot reach a backend that
  has no authentication of its own.
- Every hub service carries a `pids_limit`; Dependabot also watches the spoke
  images pinned in `templates/`. Patch bumps are grouped per directory and
  the demo's dependencies into one monthly PR; minors and majors stay one
  per PR.
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

- `just demo`: a one-command demo. An auto-instrumented FastAPI service under
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
