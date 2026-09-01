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
just logs <service>        # follow logs (otel-collector, loki, tempo, prometheus, grafana)
just restart <service>
```

Two alerts point here. `TargetDown` fires after two minutes when
Prometheus can't scrape a target, and it scrapes every service in the
stack — collector, node-exporter, Grafana, Loki, Tempo, and
itself — so the alert names whichever one went quiet.
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

Memory is bounded per service instead: every service carries a `mem_limit`
in `compose.yml`, sized from observed usage with headroom so that one
runaway component cannot take the host down with it. If a component
legitimately grows into its ceiling, raise it there.

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
- The tarball covers the docker volumes and nothing else. The OpenTofu
  state for the Cloudflare edge is not in it — see below.
- During the pause the collector keeps accepting telemetry and buffers it
  for five minutes — the `retry_on_failure.max_elapsed_time` pinned on
  every exporter in `config/otel-collector.yaml`, not an upstream default
  that can move under you. The queue is file-backed, so restarting the
  collector inside that window keeps the buffer; a backup that runs longer
  than five minutes still drops data, so on large volumes run it at a
  quiet hour.

How much history you can lose equals how often you run it. A daily cron on
the host is the intended setup.

## Rotating secrets

- **OTLP token:** set the new `OTLP_AUTH_TOKEN` in `.env`, then
  `docker compose up -d otel-collector`, then update every sender's
  `OTEL_EXPORTER_OTLP_HEADERS`. Senders still on the old token get 401s
  (visible as export errors on their side) until they're updated. A
  running demo overlay counts as a sender: re-run `just demo` to recreate
  it with the new token.
- **Tunnel token:** the tunnel is OpenTofu-managed, so read the token back
  from there rather than copying it out of the dashboard. Rotate the tunnel
  secret in Cloudflare Zero Trust, then `cd infra && tofu apply` (which
  refreshes the token data source) and `tofu output -raw tunnel_token`. To
  rotate entirely from code instead, `tofu apply -replace=cloudflare_zero_trust_tunnel_cloudflared.monitoring`
  builds a new tunnel and repoints both CNAMEs at it — ingestion and Grafana
  are unreachable for the minute or so that takes. Either way: new token into
  `CLOUDFLARE_TUNNEL_TOKEN` in `.env`, then `just up-tunnel`.
- **Grafana admin password:** change `GRAFANA_ADMIN_PASSWORD` in `.env`,
  then `docker compose up -d grafana`.

## Alert delivery

Grafana evaluates the rules and delivers them; there is no Alertmanager. Rules,
contact points and the routing tree are provisioned from
`config/grafana/alerting/`, so the UI shows them read-only — edit the YAML.
Two environment variables control where notifications go:

- `ALERT_WEBHOOK_URL` receives all alerts (any webhook: ntfy, Slack, …).
- `HEARTBEAT_URL` receives the always-firing `Watchdog` every five
  minutes. Point it at a dead man's switch (e.g. healthchecks.io) that
  raises the alarm when pings **stop** — that is the "monitoring host is
  dead" signal nothing inside the host can send.

Leaving them empty is not a safe default. Delivery then fails silently while
the heartbeat keeps pinging, so the dead man's switch reads healthy and every
real alert is dropped. `just up-tunnel` refuses to start without
`ALERT_WEBHOOK_URL`, and `AlertDeliveryFailing` fires on a failing notifier.

After changing either variable, `docker compose up -d grafana`. Compose only
recreates a container when its own definition changes, so a `.env` edit needs
that command — a plain `restart` keeps the old environment, and the stale value
survives with no indication that it has.

## Changing the Cloudflare edge

The tunnel, its ingress rules, both DNS records, and the Cloudflare Access
policy that fronts Grafana are all OpenTofu in `infra/`. Change them there,
not in the Zero Trust dashboard: the next apply reverts anything clicked in
by hand.

```sh
just infra-validate                 # tofu init + validate, in a container
cd infra && tofu plan               # needs CLOUDFLARE_API_TOKEN exported
cd infra && tofu apply
```

- **Granting or revoking Grafana access:** edit `grafana_allowed_emails` in
  `infra/terraform.tfvars` and apply. That list is the entire allowlist. A
  removed address keeps working until their Access session expires (24h),
  so for an urgent revocation also revoke the session in Zero Trust. At
  least one address has to remain — the variable's validation rejects an
  empty list, which would lock everyone out of Grafana. Check your plan's Zero
  Trust seat count before adding people: the free-plan figure ADR 0002 cites
  appears only in third-party posts, never in Cloudflare's own documentation,
  so confirm it before someone cannot log in rather than after.
- **Per-user Grafana logins:** by default everyone who clears Access then
  shares the one admin password. Setting `GRAFANA_JWT_AUTH=true` and
  `CF_ACCESS_TEAM_DOMAIN=<team>` in `.env` makes Grafana verify the Access
  JWT instead, so each address signs in as itself and new ones land on the
  org's default role (Viewer). The JWK set is team-wide, so if the Zero
  Trust team fronts more than one Access application, also pin
  `GF_AUTH_JWT_EXPECT_CLAIMS` in `compose.yml` to this app's `aud` tag —
  otherwise a token minted for any other app in the team is accepted here
  too.
- **Adding a hostname:** add an `ingress` entry pointing at the service's
  container port, plus a matching `cloudflare_dns_record`. The catch-all
  `http_status:404` entry stays last, or it swallows everything after it.
- **State lives on this host only.** `infra/terraform.tfstate` is gitignored
  and `just backup` does not touch it. Copy it off-host next to the backups.
  Losing it orphans the Cloudflare resources: they keep running, but the
  next apply tries to create duplicates and you get them back only by hand
  with `tofu import`.

## Upgrading images

Dependabot opens PRs that bump the pinned versions, and CI runs `just
check` on each one. The validators (promtool, otelcol) read their
image versions from `compose.yml`, so every bump is checked with the exact
binaries the stack will run — when a new version changes its config
syntax, CI fails loudly before the change reaches the host. That is the
point.

Dependabot also watches the Cloudflare provider in `infra/`. Those PRs need
one manual step: it bumps the constraint in `main.tf` but not the recorded
hashes in `.terraform.lock.hcl`, so check the branch out and run
`cd infra && tofu init -upgrade`, then `just infra-validate` and `tofu plan`
against the real account — validation proves the syntax parses, only a plan
proves the provider still maps the config to the same resources.

Nothing watches the tool images pinned in the `justfile` — yamllint,
actionlint, OpenTofu, jq, and the alpine that backup, restore, and the
queue-volume setup run in. No Dependabot ecosystem covers a justfile, so
those are bumped by hand.

After merging: on the host, `git pull && just pull && just up`. Bring the
stack up through `just up` rather than `docker compose up -d`: the recipe
first chowns the collector's queue volume to uid 10001, and on a host where
that volume is new a raw compose up leaves it root-owned and the collector
crash-looping on a queue directory it cannot write.
