# ADR 0002: Hub-and-spoke observability for CML projects

Date: 2026-08-20. Status: accepted; **migration complete 2026-08-28**. The
transitional HANDOVER.md that tracked it has been deleted: it described a
transition, not a system. Onboarding is [templates/README.md](../../templates/README.md).

Supersedes one decision from ADR 0001: RED metrics move off Tempo's span-metrics
and onto the applications' native OTLP HTTP metrics. Everything else in ADR 0001
stands.

## Context

This stack was built for RELab and must now serve multiple CML projects at very
different maturity levels, including GPU hosts for computer-vision work. One
part-time operator, Docker Compose everywhere, zero budget. The formative
incident: a backup container crash-looped 668 times over 19 hours while every
monitor read green. The failure modes that matter are the ones with no detector
at all.

## Decision

Three tiers, each owning distinct signals:

- **Per-project host (spoke):** one Grafana Alloy agent per host, covering
  container stdout, host metrics (node exporter), and container
  lifecycle/resources (cAdvisor). The application's own OTel SDK adds traces and
  app metrics. The agent config is one shared file published by this repo,
  parameterised only by environment variables; no project ever edits it. systemd
  timers run scheduled jobs (backups, checks) through a wrapper that pings a
  per-job dead-man's switch.
- **Central host (hub):** this stack. One OTLP/HTTP endpoint, one bearer token,
  no per-backend hostnames or credentials, ever. Grafana is the *single* home
  for alert rules and notification (Alertmanager and Prometheus rule files go
  away, because Grafana-managed rules can query Loki, which the most valuable
  alerts need).
- **Outside everything:** healthchecks.io as the per-job dead-man's switch, and
  an external HTTP prober for public reachability. These are the only detectors
  whose default state is alarm; everything else fails silent, and silence is
  indistinguishable from health.

Contracts that make it scale:

- **Five identity labels on every signal**: `project`, `env`, `service.name` and
  `host_name` (Prometheus form; OTel form is `host.name`) come from the shared
  agent config, and `department` is stamped by the gateway collector, which is
  the only component that knows it and the only one a sender cannot override.
  Cardinality rule: user ids, request ids and timestamps go in
  bodies and span attributes, never labels.
- **Each signal has exactly one producer.** Alloy owns all container logs (SDK
  log exporters stay off); native app metrics own RED; cAdvisor owns container
  lifecycle; healthchecks.io owns "did the job run"; a host-local drift script
  owns "is the deployed code the code we think"; nothing derives metrics from
  logs or from traces.
- **`ProjectTelemetrySilent` per project/env is the keystone alert**: nothing
  on a spoke can detect its own absence. Templated and provisioned by
  `bootstrap.sh`, which is also what creates a project's healthchecks and prints
  its `.env` block. Bootstrap is what creates the safety net, not the telemetry.
- **Onboarding is a copy, not a port:** vendor the template files at a pinned
  tag (three, plus one for a GPU host), add six `.env` variables, include the
  overlay, run `bootstrap.sh`. A GPU host is an ordinary host plus one opt-in
  overlay (`nvidia_gpu_exporter` scraped by Alloy, not dcgm-exporter, whose
  profiling fields are datacentre-only) and three GPU alert rules.

## Alternatives considered

- **Grafana Cloud free tier (no hub at all):** deletes this host, its backups
  and its disk-full failure mode, and the free tier covers CML's volume. Rejected
  on data protection, not economics: container logs cross the applications'
  sanitization boundary (Postgres error lines can quote research and personal
  data), and shipping them to a US-operated SaaS is a GDPR/university-policy
  problem a department-run host does not have. Revisit only if that question is
  formally cleared.
- **Per-project tokens and Loki multi-tenancy:** organisational controls for a
  problem one operator does not have. The trigger for per-project tokens is the
  first leaked-token incident; for multi-tenancy, the first dataset other CML
  projects must not see. Both are a day of work, not a redesign.
- **Pushgateway for batch/ML jobs:** rejected on Prometheus's own guidance;
  machine-level batch jobs use node_exporter's textfile collector plus a
  dead-man's-switch check.
- **A second alerting engine, SLOs, paging rotations, per-project dashboards,
  long retention:** all rejected. One operator, alert count capped around ten,
  and dashboards carry a `project` template variable instead of per-project
  copies.

## Consequences

- Tempo demotes to trace storage only; deleting its metrics-generator dependency
  makes it disposable on its next breaking upgrade.
- The spokes' local watchdog checks (service health, snapshot age, timer state)
  were deletable only once `ProjectTelemetrySilent` and the container-lifecycle
  rules were live here. Both are, and both have been seen working on real traffic:
  the keystone fired on an actual spoke outage on 2026-08-27 and resolved when the
  host came back. That tripwire has therefore been released.
- Prometheus needs `out_of_order_time_window: 30m` for OTLP ingestion; without
  it late batches drop silently. The OTLP receiver is documented as a
  low-volume path. The revisit trigger is a host exceeding a few thousand active
  series.
- Unverified at decision time: whether cAdvisor metric names survive the OTLP
  round trip (a 15-minute experiment decides between importing dashboard 15798
  and adding a second ingestion path); Cloudflare free-plan Zero Trust seat
  count.
