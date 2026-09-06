# Templates: onboarding a project onto this stack

Four files get vendored onto a project host at a pinned tag. **No project edits them.**
Everything that differs between projects arrives as an environment variable, so the
agent config on every host is byte-identical and a fix here reaches all of them.

| File | What it is |
| --- | --- |
| `alloy/config.alloy` | The one agent config: container logs, host metrics, cAdvisor, optional GPU |
| `compose.telemetry.yml` | The Alloy agent and its Docker socket proxy |
| `compose.telemetry.gpu.yml` | Opt-in overlay: `nvidia_gpu_exporter`, discovered automatically |
| `run_scheduled.sh` | Dead-man's-switch wrapper for scheduled jobs |

`alerting/project.yaml.tmpl` is not vendored; it stays here and is rendered by
`bootstrap.sh` into this stack's own alert rules.

## The whole checklist

Run `./bootstrap.sh <project> <env>` on the monitoring host. It prints the two blocks
you need: the `.env` variables to paste on the project host, and the `curl` commands
that vendor these files at a pinned tag. Then on the project host:

```sh
docker compose -f compose.yml -f compose.telemetry.yml up -d
```

Under an hour, most of it waiting for the first scrape.

## Bootstrap creates the safety net, not the telemetry

A host can ship perfect telemetry and still be unmonitored: the rule that notices its
*silence* lives on this stack, not on the host. Skipping `bootstrap.sh` leaves a
project uncovered, with no error anywhere.

The backstop is `ProjectsUncovered`, regenerated on every bootstrap run: it fires on
any series carrying a `project` label with no rendered rule file. It is the detector
for a missing detector.

## Two things that silently produce nothing

- **`cgroup: host` on the agent container.** The overlay sets it. cAdvisor finds
  containers by walking the cgroup tree, not through the Docker API, so under Docker's
  default private cgroup namespace it sees only its own cgroup, reports one root series
  with no `name` label, and every container alert matches nothing. No error is logged.
- **`OTEL_SEMCONV_STABILITY_OPT_IN=http` in an instrumented app.** Without it the SDK
  emits the legacy HTTP metric names, whose `http_target` label carries the raw request
  path: unbounded series on any API with path parameters. The stable names use
  `http_route`, and the central Service Health dashboard queries those.

## GPU hosts

Include `compose.telemetry.gpu.yml` as well. Set `GPU_METRICS=1`. The agent config
already discovers the exporter by its Compose service label, so nothing else changes:
a GPU host is an ordinary host plus one overlay.

The exporter is `nvidia_gpu_exporter`, not dcgm-exporter: DCGM's advantage is its
`DCGM_FI_PROF_*` profiling fields, which NVIDIA document as datacentre-only. On a
consumer card they are absent, and dcgm-exporter still requires `SYS_ADMIN`.

Three GPU rules are worth adding per GPU host. They are not provisioned by
`bootstrap.sh` yet:

- `nvidia_smi_gpu_recovery_action > 0`: the driver is asking for a reset. The single
  best GPU health signal.
- a thermal/power throttle flag.
- XID faults, with an explicit code allowlist rather than every code, since most XIDs
  are application faults:

  ```promql
  time() - nvidia_smi_xid_last_timestamp_seconds{xid=~"48|62|64|74|79|95|119|120"} < 300
  ```

XIDs are the GPU analogue of the crash-loop blind spot. A stuck kernel, an
uncorrectable memory fault, and a card that has fallen off the bus are all invisible to
utilisation graphs. Any of them silently kills a twelve-hour training run.

Both dashboards are provisioned centrally: `dashboards/gpu.json` (vendored from
[14574](https://grafana.com/grafana/dashboards/14574); its multi-GPU companion is
25547 if a host ever grows a second card) and `dashboards/host-containers.json` for
per-container resources. Nothing to import on the project host.

## Removing a project

Deleting `config/grafana/alerting/project-<project>-<env>.yaml` is **not** enough.
Grafana provisioning creates and updates rules from files, but it never deletes a rule
because its file vanished. The API refuses to delete a provisioned rule too (409, even
with `X-Disable-Provenance`). The orphan keeps evaluating and firing.

Delete the file, then drop the rule explicitly with a one-off provisioning file:

```yaml
# config/grafana/alerting/zz-delete.yaml (temporary)
apiVersion: 1
deleteRules:
  - orgId: 1
    uid: proj-silent-<project>-<env>
```

The file has to be temporary. Left in place, it would delete the rule again the next
time `bootstrap.sh` renders it for that project. So:

1. Restart Grafana.
2. Confirm the rule group is gone.
3. Remove `zz-delete.yaml` and restart Grafana again.
4. Re-run `bootstrap.sh` for a project that remains, so `coverage.yaml` stops listing
   the removed one as covered.

## Budgets to plan against

- **healthchecks.io free tier is exactly 20 checks.** `bootstrap.sh` creates three per
  project/environment, so that is the onboarding ceiling: about six environments.
- **Prometheus's OTLP receiver is documented as "not an efficient way of ingesting
  samples"**, for "specific low-volume use cases". A few hundred series per host at 30s
  is exactly that case. Revisit on volume: a host past a few thousand active series
  should move infrastructure metrics to `remote_write` behind an authenticating proxy,
  leaving app metrics on OTLP.

## Verifying, from the monitoring host

```promql
count({project="<project>",env="<env>"})                          # non-zero within ~2 min
count(container_start_time_seconds{project="<project>",name!=""}) # one per container
count({job="<service.name>"})                                     # app's own SDK metrics
```

If the first is zero after five minutes, `ProjectTelemetrySilent` will tell you anyway.
Expect it ~20 minutes after the last sample: `absent()` needs the series to go stale
before it reports.
