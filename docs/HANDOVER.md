# Handover: the central stack's half of the August 2026 review

Owner: Simon van Lierde
Review date: 2026-09-19

Relab's side of an architecture review is done and merged (its repo carries the full
review in `deploy/MONITORING-DESIGN.md`; the target architecture is recorded here as
[ADR 0002](adr/0002-hub-and-spoke-observability.md)). This document is the actionable
half for THIS repo: what Relab now emits, what the central stack has to do with it, and
what should be deleted here. It is written to be actionable without reading the Relab
repo.

**Delete this file once the work below is done.** It describes a transition, not a system.

______________________________________________________________________

## Why this exists

A backup container crash-looped 668 times over 19 hours. Every monitor read green the
whole time, because the only backup check was newest-snapshot age — which a crash loop
makes look *better* than healthy. It was noticed by ear, from fan noise.

Nothing here is about adding tools. It is about the fact that several failures currently
have no detector at all, and one of them is the failure that already happened.

______________________________________________________________________

## What Relab now emits

One Grafana Alloy agent per deploy host, one OTLP/HTTP endpoint, one bearer token. No new
hostnames, no new credentials, nothing to configure centrally per host.

| Signal                       | Source                                  | Notes                                                                                        |
| ---------------------------- | --------------------------------------- | -------------------------------------------------------------------------------------------- |
| Application traces + metrics | the API's own OTel SDK                  | `service.name=relab-api`                                                                     |
| Container logs               | Alloy `loki.source.docker`              | every container's stdout, labelled by Compose service                                        |
| Host metrics                 | Alloy `prometheus.exporter.unix`        | CPU, memory, load, disk, network, `hwmon`                                                    |
| Per-container metrics        | Alloy `prometheus.exporter.cadvisor`    | CPU, memory, network, disk I/O, `container_start_time_seconds`, `container_oom_events_total` |
| GPU metrics                  | `nvidia_gpu_exporter`, scraped by Alloy | opt-in overlay, present only on GPU hosts                                                    |

Every signal carries four identity labels: **`project`**, **`env`**, **`service.name`**,
**`host_name`**. Enforced by the agent config, so a host cannot omit them.

Verified live 2026-08-27, with two corrections. Alloy attaches these as **ordinary series
labels, not OTLP resource attributes** — so `target_info` carries none of them, and any rule
keyed on `target_info` is keyed on nothing. And Relab's `env` is **`staging`**, not
`production`; no `production` series exist. `config/prometheus.yaml` promotes the four
attributes anyway, for spokes whose app SDK sends them the resource-attribute way.

Application logs are **no longer** exported by the API's SDK. Alloy ships that container's
stdout, so exporting them twice stored every line twice in two shapes. The stdout path is
the one kept, because it also carries what the SDK cannot report: the SDK's own export
failures.

______________________________________________________________________

## The keystone alert, and the four behind it

Nothing on the Relab side can detect its own absence. These rules are the deliverable —
without them the telemetry is a dashboard, not monitoring.

| Rule                         | Shape                                                     | For | Catches                                                                                                              |
| ---------------------------- | --------------------------------------------------------- | --- | -------------------------------------------------------------------------------------------------------------------- |
| **`ProjectTelemetrySilent`** | no logs or metrics with `project=X, env=Y`                | 15m | Host down, Docker down, Alloy down, tunnel down, token rotated wrong, collector rejecting. **Write this one first.** |
| **`ContainerRestarting`**    | `changes(container_start_time_seconds{name!=""}[1h]) > 3` | 10m | The 668-restart incident. A crash loop becomes louder than health instead of quieter.                                |
| `ContainerOOMKilled`         | increase in `container_oom_events_total`                  | 0m  | Distinct cause, distinct fix.                                                                                        |
| `HostDiskSpaceLow`           | < 20% free, by `host_name`                                | 15m | Data already arrives; nothing reads it.                                                                              |
| `OtelExportFailures`         | collector send-failed rate > 0                            | 5m  | Backend rejecting data.                                                                                              |

Keep the total under about ten rules. Past that the operator stops reading them.

Only `ProjectTelemetrySilent` needs generating per project and environment. The rest are
generic once `host_name` and `project` labels are correct.

For GPU hosts, three more: `nvidia_smi_gpu_recovery_action > 0` (the driver wants a
reset — the best single health alert), a thermal/power throttle flag, and XID faults with
an explicit code allowlist rather than every code, since most are application faults:

```promql
time() - nvidia_smi_xid_last_timestamp_seconds{xid=~"48|62|64|74|79|95|119|120"} < 300
```

XIDs are the GPU analogue of the crash-loop blind spot: a stuck kernel, an uncorrectable
memory fault or a card off the bus are invisible to utilisation graphs, and they are what
silently kills a twelve-hour training run.

______________________________________________________________________

## Delete list for the monitoring repo

- **Alertmanager**, its volume, its `url_file` entrypoint hack, its `amtool` check step and
  its backup mount. Move every rule to Grafana-managed alert rules provisioned from YAML
  under `/etc/grafana/provisioning/alerting/`. Three reasons, by weight:

  1. **Grafana rules can query Loki; Prometheus rules cannot.** The alerts worth having are
     log-shaped and metric-shaped at once. Splitting the rule engine means the most
     valuable ones cannot be written at all.
  1. One place owns notification, instead of two answers to "who gets told".
  1. It deletes a container, a volume, a config file and a check step.

  Caveat that shapes the work: Grafana's built-in Alertmanager handles Grafana-managed
  alerts only, and there is no documented endpoint for an external Prometheus to POST into
  it. So the Prometheus rule files must genuinely *become* Grafana rules — this is not a
  re-pointing of delivery. That is four rules; an afternoon.

  *The opposite choice is right if* you want alerting to survive Grafana being down. It
  does not buy that today, because Alertmanager sits on the same host and dies with it.
  The real answer to "alerting is down" is the heartbeat below.

- **ONBOARDING templates 3 and 4** (Loki Docker driver, `loki.write` to a push hostname).
  Both document a path that requires exposing Loki, which this stack deliberately does not
  do because Loki has no authentication of its own. Relab followed template 3, and it cost
  a day to undo.

- **`compose.storage-s3.yml`** and **Tempo's span-metrics dependency** — neither is
  load-bearing; move RED metrics onto native OTLP HTTP metrics instead.

- **Grafana OnCall OSS** is not an option in 2026: maintenance mode March 2025, archived
  read-only March 2026, paid Grafana Cloud IRM the only successor. If it comes up, that is
  the answer.

______________________________________________________________________

## The heartbeat, and why it is not optional

Everything above travels through one collector over one tunnel. A dead host, a dead
collector, a broken tunnel and an expired token are indistinguishable from Grafana's point
of view: silence that looks like health.

Relab's scheduled jobs each ping a per-job dead-man's switch (healthchecks.io) directly
from the host. That is the one signal that does not share fate with this stack, and it must
stay. On the central side, add a `Watchdog` rule (`vector(1)`, always firing) routed to a
heartbeat contact point on a short repeat interval — its *silence* is the alarm.

healthchecks.io's free tier is exactly 20 checks. Relab uses three per environment; that is
the ceiling to plan against as projects onboard.

______________________________________________________________________

## Dashboards: the actual scalability lever

Today there is a per-project dashboard. N projects means N hand-maintained dashboards, and
that will stop this scaling long before storage does.

Replace with three dashboards carrying a `project` template variable — *Service Health*,
*Logs*, *Host & Containers* — so a new project gets full dashboards the moment its first
telemetry lands, with nobody editing JSON.

Import rather than author:

- per-container resources: [15798](https://grafana.com/grafana/dashboards/15798-docker-monitoring/)
  (revised 2025-07-12); [19792](https://grafana.com/grafana/dashboards/19792-cadvisor-dashboard/)
  is the Compose-aware second choice. Avoid 10619 and 893 — high download counts, untouched
  since 2019 and Grafana 4 respectively. Download counts measure inertia, not maintenance.
- GPU: [14574](https://grafana.com/grafana/dashboards/14574) (revised 2026-08-04) and its
  multi-GPU companion 25547. Do **not** use the canonical DCGM dashboard 12239: last
  revised 2021, and its panels lean on profiling fields consumer cards cannot produce.

### The one experiment to run first

Stock cAdvisor dashboards assume Prometheus *scraped* cAdvisor — they key on `job`,
`instance` and `name` as a scrape produces them. Relab's metrics arrive over OTLP, where
Prometheus reconstructs `job` from `service.name`, `instance` from `service.instance.id`,
and applies a translation strategy to metric names.

**Run and answered (2026-08-27): names survive.** Confirmed twice — once against a
scratch Prometheus v3.13.2, once against the live stack, where Relab's own
`container_cpu_usage_seconds_total` and friends are present under their exact upstream
names. So: keep the single OTLP path, import 15798, and do not reach for the experimental
`otlp.translation_strategy: NoTranslation`.

**But do not repoint 15798's variables at `host_name`/`project` yet, and do not import it
expecting per-container panels.** See the cAdvisor gap below — the per-container series the
dashboard is built on are not arriving at all.

______________________________________________________________________

## Two settings that are easy to miss

- **`out_of_order_time_window: 30m`** on Prometheus. The official OTel guide requires it for
  OTLP ingestion; without it, late batches are silently dropped. "Silently" is the operative
  word.
- **Prometheus's OTLP receiver is documented as "not an efficient way of ingesting
  samples"**, for "specific low-volume use cases". CML is exactly the case that sentence
  carves out — a few hundred series per host at 30s. The deciding factor for revisiting is
  volume: if a host exceeds a few thousand active series, move infrastructure metrics to
  `remote_write` behind an authenticating proxy and leave app metrics on OTLP.

______________________________________________________________________

## Onboarding a second project

This is the part worth doing well: it is the difference between a stack that serves CML and
one that serves Relab.

The central repo should publish:

1. `templates/alloy/config.alloy` — one shared agent config, parameterised only by
   environment variables. **Relab's `deploy/alloy/config.alloy` is this file already**,
   minus two hardcoded `"relab"` strings. No project should ever edit it.
1. `templates/compose.telemetry.yml` — Relab's `compose.logging.alloy.yaml` is ~90% of it.
1. `templates/compose.telemetry.gpu.yml` — Relab's `compose.gpu.yaml`, likewise.
1. `templates/run_scheduled.sh` — the dead-man's-switch wrapper; Relab's is generic apart
   from job names.
1. `templates/alerts/project.yaml.tmpl` — the rules above, with `{{project}}` and `{{env}}`
   substituted.
1. `bootstrap.sh <project> <env>` — renders the alert rules and reloads Grafana, creates the
   healthchecks.io checks and prints their URLs, prints the `.env` block to paste on the
   project host, and prints the `curl` that vendors the templates at a pinned tag.

A new project's whole checklist then is: vendor two files, add six `.env` variables, include
the overlay, run `bootstrap.sh`. Under an hour, most of it waiting.

One trap to design out: `ProjectTelemetrySilent` only exists for projects whose
`bootstrap.sh` was actually run. A project that ships telemetry but skipped bootstrap is
silently uncovered — the exact failure class the rule closes, one level up. Cheapest
countermeasure: one standing rule that fires on any series whose `project` label has no
matching provisioned rule group; failing that, make the onboarding doc say plainly that
bootstrap is what creates the safety net, not the telemetry.

Take the templates from Relab, then **re-vendor Relab from them**, so Relab is proof the
path works rather than a special case that drifted.

______________________________________________________________________

## Sequencing

**Tripwire first:** the owner and review date at the top of this file are load-bearing.
Relab's local watchdog checks (service health, snapshot age, timer state) are scheduled
for deletion *only after* steps 1–2 below are live and verified — if nobody has picked
this work up by the review date, the watchdog stays, and the deletion item in Relab's
`deploy/MONITORING-DESIGN.md` §2.1 must not proceed on optimism. Deleting a weak local
signal before its central replacement exists trades a weak signal for none.

1. ~~`ProjectTelemetrySilent`~~ — done and **verified against live traffic**;
   `config/alerts/projects.yaml`. Keyed on a label-only selector, `project`/`env` on the
   series themselves, because `target_info` carries no identity labels here.
1. `ContainerRestarting` + `ContainerOOMKilled` — written (`config/alerts/stack.yaml`,
   group `container-lifecycle`) but **blind: no data reaches them.** See below. This is
   the open item; the incident that started all of this is still undetected.
1. ~~Run the metric-name experiment~~ — done, names survive. Import of 15798/14574 is
   blocked behind the same cAdvisor gap.
1. `HostDiskSpaceLow`, `OtelExportFailures`, `Watchdog` heartbeat.
1. Grafana-managed alerting; delete Alertmanager.
1. Generic dashboards with a `project` variable.
1. Templates and `bootstrap.sh`; re-vendor Relab from them.

Steps 1–2 convert this from telemetry into monitoring. Everything after is leverage.

### What live verification found (2026-08-27)

Checked against the running stack with Relab reporting. Step 1 holds. Step 2 does not.

- **cAdvisor sends only the root cgroup.** `container_start_time_seconds`,
  `container_oom_events_total` and every other `container_*` metric have exactly **one**
  series each, `id="/"`, and there is no `name` label on any of them. So
  `changes(container_start_time_seconds{name!=""}[1h]) > 3` matches zero series and
  **`ContainerRestarting` can never fire**; `ContainerOOMKilled` sees only host-level OOM
  and cannot say which container. The 668-restart incident would still be invisible today.

  The fix is on the spoke, not here: Relab's Alloy needs the mounts
  `prometheus.exporter.cadvisor` requires to see container cgroups (Docker socket,
  `/sys/fs/cgroup`, `/var/lib/docker`). Nothing in this repo can close it. **Until it is
  closed, the tripwire holds and Relab's local watchdog checks stay.**

- **30% of all OTLP metric writes were being rejected** — 19,585 HTTP 400s, 1,307 points
  dropped every 30 seconds, silently, for as long as the counters go back.
  `prometheus_tsdb_out_of_order_samples_total` matched the 400 count exactly: every
  rejection was an out-of-order sample. Fixed by the `out_of_order_time_window` this branch
  already carried; zero rejections since.

  Two operational notes worth keeping. `out_of_order_time_window` is **not applied by a
  config reload** — SIGHUP logs a successful load and leaves the window at 0. It needs
  `docker compose up -d --force-recreate prometheus`; plain `up -d` and `restart` are both
  no-ops for a config-only change. And this failure mode is exactly what `OtelExportFailures`
  exists to catch, which means it had been firing, unread, the whole time.

- **`relab-api`'s own SDK metrics are not arriving.** The only jobs carrying
  `project="relab"` are `gpu`, `integrations/self`, `integrations/unix` and
  `integrations/cadvisor` — all Alloy. The emission table above claims app traces and
  metrics under `service.name=relab-api`; the metrics half is not there. Traces were not
  checked.

______________________________________________________________________

## Be skeptical of these

This came from an architecture review that verified claims against current documentation and
flagged what it could not. One is still worth checking rather than trusting:

- the Cloudflare Zero Trust free-plan seat count — the widely-cited figure appears only in
  third-party posts, never in Cloudflare's own docs;
- ~~the OTLP metric-name round trip~~ — run on 2026-08-27; names survive. See above.

There is also **no official cadence recommendation** for `restic check --read-data-subset`;
the commonly repeated "1/12 monthly" is forum folklore. Pick a cadence, write down why, and
treat the number as arbitrary-but-declared.
