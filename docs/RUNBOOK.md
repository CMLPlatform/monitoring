# Runbook

How to operate this stack. All commands run from the repo root on the
monitoring host. Start with `just ps` and the **Stack Health** dashboard;
between them they answer most "what is wrong" questions.

![Stack Health dashboard](img/stack-health.png)

That capture is honest, not staged: the red export-failure spike is a real
Tempo outage after a bad major-version bump, and the gap in the ingest
panel is a backup/restore drill. Both procedures are below.

## A service is down or misbehaving

```sh
just ps                    # what's running, what's restarting
just logs <service>        # follow logs (otel-collector, loki, tempo, prometheus, grafana, alertmanager)
just restart <service>
```

Two alerts point here. `TargetDown` fires after two minutes when
Prometheus can't scrape the collector, node-exporter, or itself.
`OtelExportFailures` means the collector is up but a backend is rejecting
its data, so look at that backend's logs, not the collector's.

## Disk filling up (`HostDiskSpaceLow`)

Retention is only partially size-bounded, and that's by design rather than
oversight:

| Data | Time limit | Size limit |
| --- | --- | --- |
| Container stdout logs | — | json-file 10m × 3 per service |
| Prometheus TSDB | 30d | 15GB (`--storage.tsdb.retention.size`) |
| Loki chunks | 30d | none — Loki cannot cap total size |
| Tempo blocks | 7d | none |

Loki and Tempo simply have no total-size knob, which is why the disk alert
at 80% is the real backstop. When it fires: check the Filesystem panel on
Stack Health, then either free space or shorten a retention window
(`retention_period` in `config/loki.yaml`, `block_retention` in
`config/tempo.yaml`, the `--storage.tsdb.retention.*` flags in
`compose.yml`) and restart the affected service. If disk pressure keeps
coming back, the durable fix is moving Loki and Tempo to object storage —
see `compose.storage-s3.yml`.

## Backup and restore

```sh
just backup                # pauses stateful services for seconds, writes backups/monitoring-<ts>.tar.gz
just restore backups/monitoring-<ts>.tar.gz   # stops the stack, wipes volumes, restores
just up
```

Backups are crash-consistent: restoring one is equivalent to recovering
from a power loss, which every component in the stack does cleanly via its
write-ahead log. Two practical notes:

- The tarball is mode 0600 and contains secrets (the Grafana database
  among them). Copy it off-host over a private channel — a backup on the
  disk it protects is a decoration.
- During the pause the collector keeps accepting telemetry and buffers it
  for about five minutes. A backup that takes longer than that will drop
  data, so on large volumes run it at a quiet hour.

How much history you can lose equals how often you run it. A daily cron on
the host is the intended setup.

## Rotating secrets

- **OTLP token:** set the new `OTLP_AUTH_TOKEN` in `.env`, then
  `docker compose up -d otel-collector`, then update every sender's
  `OTEL_EXPORTER_OTLP_HEADERS`. Senders still on the old token get 401s
  (visible as export errors on their side) until they're updated. A
  running demo overlay counts as a sender: re-run `just demo` to recreate
  it with the new token.
- **Tunnel token:** rotate in Cloudflare Zero Trust, set the new
  `CLOUDFLARE_TUNNEL_TOKEN` in `.env`, then `just up-tunnel`.
- **Grafana admin password:** change `GRAFANA_ADMIN_PASSWORD` in `.env`,
  then `docker compose up -d grafana`.

## Alert delivery

Prometheus evaluates the rules; Alertmanager delivers them. Two
environment variables control where:

- `ALERT_WEBHOOK_URL` receives all alerts (any webhook: ntfy, Slack, …).
- `HEARTBEAT_URL` receives the always-firing `Watchdog` every five
  minutes. Point it at a dead man's switch (e.g. healthchecks.io) that
  raises the alarm when pings **stop** — that is the "monitoring host is
  dead" signal nothing inside the host can send.

Leaving both empty is fine: nothing is delivered, Alertmanager logs one
notify error per cycle (expected, harmless), and alerts remain visible in
Grafana. After changing either variable, `docker compose up -d
alertmanager`.

## Upgrading images

Dependabot opens PRs that bump the pinned versions, and CI runs `just
check` on each one. The validators (promtool, otelcol, amtool) read their
image versions from `compose.yml`, so every bump is checked with the exact
binaries the stack will run — when a new version changes its config
syntax, CI fails loudly before the change reaches the host. That is the
point.

After merging: on the host, `git pull && just pull && just up`.
