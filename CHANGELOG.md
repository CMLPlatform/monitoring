# Changelog

Notable changes to this stack. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

## [0.3.1] - 2026-09-07

### Upgrade

- Re-vendor `compose.telemetry.yml` on each spoke at `v0.3.1` for Alloy
  v1.19.2.

### Added

- Pushing a `v*` tag cuts the GitHub release. The workflow takes the tag's
  section of this file as the body and refuses a tag without one, or one that
  fails `just check`.

### Changed

- **`PrometheusCardinalityHigh` fires at 30k active series, not 100k.** 100k
  would have put Prometheus near its 2g `mem_limit` before the warning
  arrived; 30k is ~18 spokes of room.
- **New `PrometheusCardinalitySpike`**, on 5,000 new series in 30 minutes: a
  label that explodes, which a ceiling cannot catch. One spoke onboarding adds
  ~1,400.
- Hub images: Grafana 13.2.1, Prometheus v3.14.0, otel-collector-contrib
  0.160.0. Dependabot groups the `/infra` provider bumps and action advisories.

### Fixed

- **Prometheus rejected the ingest counters every few minutes**, so five of
  eight `telemetry_logs_total` senders never reached it. Both coverage alerts
  read that counter. Three faults: `batch` reordered timestamps after
  `deltatocumulative`; the count connector emitted one sample per incoming
  batch, which Prometheus rejects as duplicates; and the counters carried the
  source telemetry's timestamp, so a log backlog fell outside
  `out_of_order_time_window`. The pipeline now drops `batch`, collapses each
  stream to one sample per 30s, and stamps samples on receipt.
- The ingest counters get their own `otlp_http/prometheus_count` exporter, so
  their send failures are counted apart from a spoke's application metrics.
- `deltatocumulative` streams are capped at 5000. A service that mints a new
  `service.instance.id` per restart added one each time.
- `ProjectsUncovered` no longer fires for `demo/demo`, the pair `just demo`
  sets. A real project named `demo` is still caught.

## [0.3.0] - 2026-09-06

The hub runs the department's telemetry in production, with one spoke on the
contract (hostname, labels, templates pinned by tag). This release hardens the
stack around that contract and makes the checks prove the data paths, not just
the config syntax. 1.0 waits for a second consumer to confirm the contract.

### Upgrade

- Point every spoke's `OTEL_EXPORTER_OTLP_ENDPOINT` at `otel.<domain>`. The
  old `otlp.<domain>` name is gone.
- Set `COMPOSE_FILE` in `.env` to name the overlays this host runs
  (`compose.yml:compose.tunnel.yml` in production). `just up-tunnel` is gone;
  `just up` runs the exposure guards whenever the tunnel overlay is active.
- Remove the orphaned `alertmanager_data` volume when convenient. Alerting is
  Grafana-managed (ADR 0002).
- Re-vendor the templates on each spoke at `v0.3.0` (`bootstrap.sh` prints
  the commands): the Alloy agent gains a memory limiter, keeps only the four
  cAdvisor metrics this stack reads, and drops its own histogram buckets; the
  overlay declares the `egress` network it joins.
- Loki streams keep their old label set until they age out (30 days).
- Set `project` as well as `env` in every sender's
  `OTEL_RESOURCE_ATTRIBUTES`. A sender that omits either is now counted as
  `unknown` and raises `ProjectsUncovered` instead of arriving unattributed
  and unnoticed.

### Added

- **Per-user Grafana logins** through Cloudflare Access: `GRAFANA_JWT_AUTH`
  with `CF_ACCESS_TEAM_DOMAIN` and `CF_ACCESS_AUD`. The exposure guards
  enforce the pair, and the smoke test boots with it on.
- **Durable export queue**: the collector's send queues live on a file-backed
  `otel_queue` volume, so telemetry buffered during an outage survives a
  collector restart. A one-shot `otel-queue-init` service owns the volume for
  the collector, so a plain `docker compose up` works and `down --volumes`
  reclaims it.
- **Self-monitoring covers every service**: Prometheus scrapes Grafana, Loki
  and Tempo too. `HostDiskFilling` (full within 3 days at the current rate)
  and `PrometheusCardinalityHigh` (over 100k active series) warn ahead of the
  80% disk backstop.
- **Per-project ingest counters**: the gateway counts what arrives and emits
  `telemetry_{datapoints,logs,spans}_total` by project and environment
  (`metrics` and `spanevents` are counted once, without labels). The rules
  match `telemetry_.+_total`; `ProjectTelemetrySilent` and `ProjectsUncovered`
  key on those instead of scanning every project-labelled series, so their cost is flat in
  fleet size, and a project that sends only logs or only traces is covered at
  last: it reached no Prometheus series before. Stack Health gains an Ingest
  by Project panel.
- **`grafana_access_team_domain`** joins the OpenTofu outputs, so neither
  Access value is copied out of the dashboard by hand. Grafana builds its JWK
  set URL from the team name, and an unset one fetches signing keys from a
  claimable subdomain.
- **`infra/generate-imports.sh`** emits OpenTofu `import` blocks for the
  tunnel, DNS records and Access app built by hand, so the first plan does
  not create duplicates.
- **`just smoke` proves the stack works, not that it boots**: every dashboard
  and alert rule provisioned, uid for uid, none paused; contact points carry
  the exact URLs given; Grafana honours the JWT settings and refuses a forged
  token; every scrape target is up; a metric and a log round-trip through
  the collector into Prometheus and Loki with the `project`, `env` and
  `department` labels. With `SMOKE_ALERTS=1` (on in CI) it also stops a
  scrape target and waits for `TargetDown` to fire. `just restore-check`
  rehearses backup and restore on the smoke volumes.
- **`just check` is `lint` plus `validate`**. `lint` covers compose files,
  the rendered alert templates, YAML formatting, workflows, shell scripts,
  the demo's Python, OpenTofu formatting, dashboard JSON and the datasource
  uids it names, and git history for secrets. `validate` runs each stack
  config through the exact image the stack uses. `just hooks` installs git
  hooks via prek: gitleaks at commit, a Conventional Commits check on the
  message, `check` at push, `infra-validate` at push when `infra/` changed.
- Dependabot watches the spoke images in `templates/` and the Cloudflare
  provider in `infra/`. Patch bumps arrive grouped.

### Changed

- **Loki indexes only the identity labels** (`service.name`, `department`,
  `project`, `env`, `host.name`). Everything else is structured metadata, so
  a sender restart no longer mints a new stream.
- **Half the series are gone.** Prometheus drops the histogram buckets from
  the Grafana, Loki and Tempo self-scrapes, the hub's node-exporter runs the
  same nine-collector allowlist the spokes' Alloy does, and the agent keeps
  only the four cAdvisor metrics this stack reads and drops its own buckets.
  Measured on the hub with one spoke: 14.1k active series to 7.0k, 438
  samples/s to 206. Nothing that a dashboard, alert or runbook reads was
  dropped; `_sum` and `_count` survive, so latency is still there to explore.
  `PrometheusCardinalityHigh`'s 100k ceiling is ~14x the baseline now.
- **Dashboards are provisioned, not editable**: `dashboards/*.json` is the
  source of truth; UI saves are off.
- **Tempo stores traces and nothing else**: its metrics generator is gone.
  RED comes from the applications' own OTLP metrics (ADR 0002).
- CI runs on pull requests only and validates `infra/` on its own workflow.
  `lint` and `validate` + `smoke` run on separate jobs. `just demo-build` is
  gone, and nothing in CI builds the demo image; `just demo` is the check.
- `just smoke` and `just demo` each run under their own compose project and
  Grafana port (`compose.sandbox.yml`), so neither can touch a running stack.
- Image bumps: Grafana 13.1.4, Loki 3.7.6, Tempo 3.0.3, Prometheus 3.13.2,
  the collector 0.156.0, node-exporter 1.12.1, cloudflared 2026.8.2, and the
  demo's Python dependencies. The `relab-api` dashboard is dropped; the
  `$service` picker on Service Health covers it.

### Fixed

- **`HighErrorRate` measured the wrong thing twice**: it counted all spans,
  so child spans diluted the ratio, and it aggregated by job alone, so a
  healthy prod service masked a broken staging one. It now reads the HTTP
  server metrics, keyed on job, project and env.
- Both onboarding templates and the demo set `env` but not `project` in
  `OTEL_RESOURCE_ATTRIBUTES`, so an app that followed them shipped telemetry
  no alert or dashboard could attribute to a project.
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
  its rule back from Grafana after the restart, and says so when the admin
  password is missing or rejected instead of blaming the rule.
- `TargetDown` and `HostDiskSpaceLow` could never fire on the state they
  watch: `up == 0` and a 0% free ratio both evaluate to 0, and the threshold
  node fires on value > 0. `HostDiskFilling` had the same defect from a
  negative projection. All three carry `bool` now, and the smoke alert
  round trip guards the contract.
- `just backup` lost tar's exit status behind the gzip pipe; a partial
  archive reported success. `just restore-check` no longer inherits the
  host's `COMPOSE_FILE`.
- The stack-health dashboard's host panels averaged spoke node metrics into
  the hub's CPU, memory and disk. They are scoped to the hub's `node` job.
- Grafana and the collector wait for Prometheus to report ready instead of
  racing it on a cold start. The demo load generator's error rate matches
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
  an `https://` root URL, non-default credentials, a webhook URL, and with
  `.env` or the OpenTofu state readable by other local users.
  `just lint` runs those guards both ways.
- Hub images are digest-pinned, GitHub Actions are pinned to commit SHAs, the
  tunnel token reaches cloudflared via environment rather than argv, the
  smoke test's ingest token reaches curl through its stdin config, and
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
