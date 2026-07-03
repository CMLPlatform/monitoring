# Runbook

Operational procedures for this stack. Commands run from the repo root on
the monitoring host. `just ps` and the **Stack Health** dashboard are the
first stop for anything.

![Stack Health dashboard](img/stack-health.png)

(That capture is honest: the red export-failure spike is a Tempo outage
after a bad major-version bump, and the ingest gap is a backup/restore
drill — both procedures below.)

## A service is down / misbehaving

```sh
just ps                    # what's running, what's restarting
just logs <service>        # follow logs (otel-collector, loki, tempo, prometheus, grafana, alertmanager)
just restart <service>
```

`TargetDown` fires after 2 minutes if Prometheus can't scrape the collector,
node-exporter, or itself. `OtelExportFailures` means the collector is up but
a backend is rejecting data — check that backend's logs.

## Disk filling up (`HostDiskSpaceLow`)

Retention is only partially size-bounded by design:

| Data | Time limit | Size limit |
| --- | --- | --- |
| Container stdout logs | — | json-file 10m × 3 per service |
| Prometheus TSDB | 30d | 15GB (`--storage.tsdb.retention.size`) |
| Loki chunks | 30d | none — Loki cannot cap total size |
| Tempo blocks | 7d | none |

So when the 80% alert fires: check the Filesystem panel on Stack Health,
then either free space or shorten retention — `retention_period` in
`config/loki.yaml`, `block_retention` in `config/tempo.yaml`, the
`--storage.tsdb.retention.*` flags in `compose.yml` — and restart the
affected service. If disk pressure is chronic, move Loki/Tempo to object
storage: `compose.storage-s3.yml`.

## Backup and restore

```sh
just backup                # pauses stateful services for seconds, writes backups/monitoring-<ts>.tar.gz
just restore backups/monitoring-<ts>.tar.gz   # stops the stack, wipes volumes, restores
just up
```

Backups are crash-consistent (equivalent to a power loss; every component
recovers via its WAL). Tarballs are mode 0600 and contain secrets (Grafana
DB); copy them off-host over a private channel — a backup on the disk it
protects is a decoration. RPO = however often you run it; a daily cron on
the host is the intended setup. During the pause the collector keeps
accepting telemetry and retries for ~5 minutes; a backup that takes longer
than that will drop data, so on large volumes run it at a quiet hour.

## Rotating secrets

- **OTLP token:** new value for `OTLP_AUTH_TOKEN` in `.env` →
  `docker compose up -d otel-collector` → update every sender's
  `OTEL_EXPORTER_OTLP_HEADERS`. Senders with the old token get 401s (visible
  as their export errors) until updated. That includes a running demo
  overlay — re-run `just demo` to recreate it with the new token.
- **Tunnel token:** rotate in Cloudflare Zero Trust → new
  `CLOUDFLARE_TUNNEL_TOKEN` in `.env` → `just up-tunnel`.
- **Grafana admin password:** `GRAFANA_ADMIN_PASSWORD` in `.env` →
  `docker compose up -d grafana`.

## Alert delivery

Prometheus evaluates rules → Alertmanager delivers:

- `ALERT_WEBHOOK_URL` — all alerts (any webhook receiver: ntfy, Slack, …).
- `HEARTBEAT_URL` — the always-firing `Watchdog` posts here every 5 minutes.
  Point it at a dead man's switch (e.g. healthchecks.io) that alerts when
  pings **stop**: that is the "monitoring host is dead" signal nothing
  inside the host can send.

Both empty = no delivery; Alertmanager logs a notify error per cycle, which
is expected and harmless. After changing either, `docker compose up -d
alertmanager`.

## Upgrading images

Dependabot PRs bump the pins. For each: CI runs `just check`; after merge,
on the host: `git pull && just pull && just up`. The `just check` validators
(promtool, otelcol, amtool) read their image versions from `compose.yml`, so
every bump is validated with the exact binaries the stack will run — CI
fails loudly when config syntax drifts between versions, which is the point.
Tempo majors are deliberately held back (see the comment in `compose.yml`).
