# Changelog

Notable changes to this stack. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

## [1.0.0] - 2026-09-06

The hub now runs the department's telemetry in production, and the contract a
spoke vendors (hostname, labels, templates pinned by tag) is the one we intend
to keep. This release hardens the stack around that contract and makes the
checks prove the data paths, not just the config syntax.

### Upgrade

- Point every spoke's `OTEL_EXPORTER_OTLP_ENDPOINT` at `otel.<domain>`. The
  old `otlp.<domain>` name is gone, and so is any edge rule that matched it.
- Set `DEPARTMENT` in the hub's `.env`. The collector stamps it on every
  signal; the alert rules and dashboards key on it.
- Set `COMPOSE_FILE` in `.env` to name the overlays this host runs
  (`compose.yml:compose.tunnel.yml` in production). `just up-tunnel` is gone;
  `just up` runs the exposure guards whenever the tunnel overlay is active.
- Remove the orphaned `alertmanager_data` volume when convenient. Alerting is
  Grafana-managed (ADR 0002); delivery still posts to `ALERT_WEBHOOK_URL`.
- Re-vendor the templates on each spoke at `v1.0.0` (`bootstrap.sh` prints
  the commands): the Alloy agent gains an in-pipeline memory limiter, and the
  overlay declares the `egress` network it joins.
- Loki streams keep their old label set until they age out (30 days).

### Added

- **Per-user Grafana logins** through Cloudflare Access: `GRAFANA_JWT_AUTH`
  with `CF_ACCESS_TEAM_DOMAIN` and `CF_ACCESS_AUD`. The exposure guards
  enforce the pair, and the smoke test boots with it on.
- **Durable export queue**: the collector's send queues live on a file-backed
  `otel_queue` volume, so telemetry buffered during an outage survives a
  collector restart.
- **Self-monitoring covers every service**: Prometheus scrapes Grafana, Loki
  and Tempo too, so `TargetDown` sees them. `HostDiskFilling` (full within 3
  days at the current rate) and `PrometheusCardinalityHigh` (over 100k active
  series) warn ahead of the 80% disk backstop.
- **`infra/generate-imports.sh`** emits OpenTofu `import` blocks for the
  tunnel, DNS records and Access app built by hand, so the first plan does
  not create duplicates of objects already serving traffic.
- **`just smoke` proves the stack works, not that it boots**: every dashboard
  and alert rule provisioned, uid for uid, none paused; contact points carry
  the exact URLs given; Grafana honours the JWT settings and refuses a forged
  token; every scrape target is up; a metric and a log round-trip through
  the collector into Prometheus and Loki with the `project`, `env` and
  `department` labels. `just restore-check` rehearses backup and restore on
  the smoke volumes.
- **`just check` is `lint` plus `validate`**. `lint` covers compose files,
  the rendered alert templates, YAML and its formatting, workflows, shell
  scripts, the demo's Python, OpenTofu formatting, dashboard JSON and the
  datasource uids it names, and git history for secrets. `validate` runs each
  stack config through the exact image the stack uses. `just hooks` installs
  git hooks via prek: gitleaks at commit, a Conventional Commits check on the
  message, `check` at push.
- Dependabot watches the spoke images in `templates/` and the Cloudflare
  provider in `infra/`; patch bumps arrive grouped, the demo's advisories in
  one PR.

### Changed

- **Loki indexes only the identity labels** (`service.name`, `department`,
  `project`, `env`, `host.name`; the list lives in `config/loki.yaml`).
  Everything else is structured metadata, so a sender restart no longer
  mints a new stream.
- **Dashboards are provisioned, not editable**: `dashboards/*.json` is the
  source of truth; UI saves are off.
- **Tempo stores traces and nothing else**: its metrics generator is gone.
  RED comes from the applications' own OTLP metrics (ADR 0002).
- CI runs on pull requests only (`main` requires one), skips prose-only
  changes, and validates `infra/` on its own workflow. `lint` and
  `validate` + `smoke` run on separate jobs, so a lint failure never waits
  on the stack images. `just demo-build` is gone; the demo is a local
  fixture.
- `just smoke` and `just demo` each run under their own compose project and
  Grafana port (`compose.sandbox.yml`), so neither can touch a running stack.
- Image bumps: Grafana 13.1.4, Loki 3.7.6, Tempo 3.0.3, Prometheus 3.13.2,
  the collector 0.156.0, node-exporter 1.12.1, cloudflared 2026.8.2, and the
  demo's Python dependencies. The `relab-api` dashboard is dropped; the
  `$service` picker on Service Health covers it.

### Fixed

- **`HighErrorRate` measured the wrong thing twice**: it counted all spans,
  so child spans diluted the ratio; and it aggregated by job alone, so a
  healthy prod service masked a broken staging one. It reads the HTTP server
  metrics now, keyed on job, project and env.
- Trace links from the latency panel resolved to nothing: exemplars carry
  `traceID`, the datasource looked for `trace_id`.
- The Infrastructure Logs dashboard queried labels this stack never set. The
  GPU dashboard's host picker keyed on `instance`, identical on every host.
- The spoke overlay joined an `egress` network it never declared, so the
  documented `up -d` failed on a host without one. `just lint` renders both
  spoke overlays now.
- With `GRAFANA_JWT_AUTH=true` and no team domain, Grafana fetched signing
  keys from a placeholder `cloudflareaccess.com` subdomain any customer could
  claim. There is no fallback now, and the guards refuse to start.
- Checks that could pass without checking: the exposure-guard self-test
  dropped the status of its positive half; the smoke provisioning check
  accepted an empty dashboard list; `just backup` exited 0 with the stack
  still paused when the unpause failed; `bootstrap.sh` printed the hash of
  empty input for a template missing from the tag; `generate-imports.sh`
  reported a failed DNS API call as "no record". `bootstrap.sh` now reads
  its rule back from Grafana after the restart instead of trusting it.
- Grafana and the collector wait for Prometheus to report ready instead of
  racing it on a cold start. The demo load generator's error rate matched
  its advertised one in ten.

### Security

- Every service drops all capabilities, runs with `no-new-privileges`, and
  carries `mem_limit` and `pids_limit` sized from observed usage.
  node-exporter and cloudflared run read-only; the demo runs as `nobody`.
- Loki, Tempo, Prometheus and node-exporter sit on an internal `backend`
  network only Grafana and the collector join. cloudflared stays outside it,
  so an ingress edited in the Cloudflare dashboard cannot reach a backend
  with no authentication of its own.
- `GRAFANA_COOKIE_SECURE` marks the session cookie Secure with strict
  SameSite. With the tunnel overlay, `just up` refuses to start without it,
  an `https://` root URL, non-default credentials, and a webhook URL;
  `just lint` runs those guards both ways.
- Hub images are digest-pinned, GitHub Actions are pinned to commit SHAs, the
  tunnel token reaches cloudflared via environment rather than argv, and
  `bootstrap.sh` prints `sha256sum -c` lines for the files a spoke vendors.

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
