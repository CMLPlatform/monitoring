# Onboarding a project host

Four files get vendored onto a project host at a pinned tag. **No project
edits them.** Everything that differs between projects arrives as an
environment variable, so the agent config on every host is byte-identical and
a fix here reaches all of them.

| File | What it is |
| --- | --- |
| `alloy/config.alloy` | The agent config: container logs, host metrics, cAdvisor, optional GPU |
| `compose.telemetry.yml` | The Alloy agent and its Docker socket proxy |
| `compose.telemetry.gpu.yml` | Opt-in overlay: `nvidia_gpu_exporter`, discovered automatically |
| `run_scheduled.sh` | Dead man's switch wrapper for scheduled jobs |

`alerting/*.tmpl` are not vendored. `bootstrap.sh` renders them into this
stack's own alert rules.

## The checklist

1. On the monitoring host, run `./bootstrap.sh <project> <env>`. It prints
   the `.env` variables for the project host and the `curl` commands that
   vendor the files at a pinned tag.
2. On the project host, paste the variables, run the curls, and bring the
   overlay up:

   ```sh
   docker compose -f compose.yml -f compose.telemetry.yml up -d
   ```

3. Verify from the monitoring host (see below).

Skipping `bootstrap.sh` leaves a project unmonitored with no error anywhere.
The rule that notices a host's *silence* lives on this stack, not on the
host. The backstop is `ProjectsUncovered`, regenerated on every bootstrap
run: it fires on any series with a `project` label that has no rendered rule
file.

## Two settings that silently produce nothing

- **`cgroup: host` on the agent container.** The overlay sets it. cAdvisor
  finds containers by walking the cgroup tree, so under Docker's default
  private cgroup namespace it sees only its own cgroup. It then reports one
  root series with no `name` label, and every container alert matches
  nothing. No error is logged.
- **`OTEL_SEMCONV_STABILITY_OPT_IN=http` in an instrumented app.** Without
  it the SDK emits the legacy HTTP metric names, whose `http_target` label
  carries the raw request path: unbounded series on any API with path
  parameters. The Service Health dashboard queries the stable names.

## GPU hosts

Include `compose.telemetry.gpu.yml` as well and set `GPU_METRICS=1`. The
agent config discovers the exporter by its Compose service label, so nothing
else changes.

The exporter is `nvidia_gpu_exporter`, not dcgm-exporter. DCGM's profiling
fields are datacentre-only, so on a consumer card it offers nothing extra and
still requires `SYS_ADMIN`.

`bootstrap.sh` does not provision GPU alert rules. The signals worth alerting
on per GPU host:

- `nvidia_smi_gpu_recovery_action > 0`: the driver is asking for a reset.
- A thermal or power throttle flag.
- XID faults, with an explicit code allowlist, since most XIDs are
  application faults:

  ```promql
  time() - nvidia_smi_xid_last_timestamp_seconds{xid=~"48|62|64|74|79|95|119|120"} < 300
  ```

A stuck kernel, an uncorrectable memory fault, or a card that has fallen off
the bus are all invisible to utilisation graphs. XIDs are how they show.

Both dashboards are provisioned centrally: `dashboards/gpu.json` (vendored
from [14574](https://grafana.com/grafana/dashboards/14574)) and
`dashboards/host-containers.json`. Nothing to import on the project host.

## Removing a project

Deleting `config/grafana/alerting/project-<project>-<env>.yaml` is **not**
enough. Grafana provisioning never deletes a rule because its file vanished,
and the API refuses to delete a provisioned rule (409). The orphan keeps
evaluating and firing.

1. Delete the project file.
2. Add a temporary provisioning file that drops the rule:

   ```yaml
   # config/grafana/alerting/zz-delete.yaml (temporary)
   apiVersion: 1
   deleteRules:
     - orgId: 1
       uid: proj-silent-<project>-<env>
   ```

3. Restart Grafana and confirm the rule group is gone.
4. Remove `zz-delete.yaml` and restart Grafana again. Left in place, it
   deletes the rule again the next time `bootstrap.sh` renders it.
5. Re-run `bootstrap.sh` for a project that remains, so `coverage.yaml` stops
   listing the removed one as covered.

## Limits

The healthchecks.io free tier is 20 checks. `bootstrap.sh` creates three per
project/environment, so about six environments fit.

## Verifying, from the monitoring host

```promql
count({project="<project>",env="<env>"})                          # non-zero within ~2 min
count(container_start_time_seconds{project="<project>",name!=""}) # one per container
count({job="<service.name>"})                                     # app's own SDK metrics
```

If the first is still zero after five minutes, `ProjectTelemetrySilent`
will say so: it fires after 15 minutes without data, or about 20 minutes
after the last sample once a project has sent any, because `absent()` needs
the series to go stale first.
