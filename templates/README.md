# Onboarding a project and its machine

Repos receive the spoke files through the CML overlay: two Copier templates in
[`copier.yml`](../copier.yml), picked by `layer`, each rendering only its own
folder under `spoke/`, each with its own answers file. They are applied after a
repo's own template. **No repo edits the files they vendor.** Everything that
differs between projects arrives as an answer or an environment variable, so
the agent config on every machine is byte-identical and a fix here reaches all
of them.

- **The project layer** (`spoke/project/`), in every project repo, answers in
  `.copier-answers.cml.yml`:

  | File | What it is |
  | --- | --- |
  | `scripts/run_scheduled.sh` | Dead man's switch wrapper for scheduled jobs |
  | `telemetry.env.example` | The project's non-secret `.env` variables, including the app SDK's |

- **The host layer** (`spoke/host/`), once per machine, in the repo that owns
  the machine, answers in `.copier-answers.cml-host.yml`:

  | File | What it is |
  | --- | --- |
  | `deploy/alloy/config.alloy` | The agent config: container logs, host metrics, cAdvisor, optional GPU |
  | `deploy/alloy/projects.alloy` | Rendered from `stacks`: which Compose project reports as which project/env |
  | `compose.telemetry.yml` | The Alloy agent and its Docker socket proxy |
  | `compose.telemetry.gpu.yml` | Opt-in overlay: `nvidia_gpu_exporter`, discovered automatically (only with `gpu=true`) |
  | `telemetry-host.env.example` | The agent's non-secret `.env` variables |

Both layers ask for `project` and `env` (the labels `bootstrap.sh` takes, so
the same `[a-z0-9][a-z0-9-]*`) and the hub's OTLP endpoint. The project layer
adds an optional contact address. For the host layer, `project` and `env` name
the machine's owner, whose labels host-level series carry, and it adds `gpu`
and `stacks`: every Compose project on the machine as
`compose-project=project/env`, space separated. The agent ships no container of
a Compose project `stacks` does not name. `just overlay-check` renders both
layers and compares each vendored file with its source here.

[ADR 0003](../docs/adr/0003-spoke-files-as-copier-overlay.md) says why there
are two layers and why an app's own telemetry goes straight to the hub.

`alerting/*.tmpl` are not vendored. `bootstrap.sh` renders them into this
stack's own alert rules. `web/` is a snippet pasted into a page, not vendored.

## The checklist

1. On the monitoring host, run `./bootstrap.sh <project> <env>`. It provisions
   the alert rules and prints the `copier` commands pinned at the latest tag.
2. In the project's repo, apply the project layer and commit what it writes:

   ```sh
   copier copy --vcs-ref=<tag> --data project=<project> --data env=<env> \
       gh:CMLPlatform/monitoring .
   ```

3. In the repo that owns the machine, apply the host layer, or add the
   project's Compose project to its `stacks` if it is there already:

   ```sh
   copier copy --vcs-ref=<tag> --data layer=host \
       --answers-file .copier-answers.cml-host.yml \
       --data project=<owner> --data env=<owner env> \
       --data stacks='<compose-project>=<project>/<env> ...' \
       gh:CMLPlatform/monitoring .
   ```

4. On the machine, add the lines of each `*.env.example` to its repo's `.env`,
   fill in `OTLP_AUTH_TOKEN`, and bring the agent up where the host layer lives:

   ```sh
   docker compose -f compose.yml -f compose.telemetry.yml up -d
   ```

5. Verify from the monitoring host (see below).

## Upgrading a spoke

A new monitoring tag reaches each layer as a diff to review:

```sh
copier update --answers-file .copier-answers.cml.yml --vcs-ref=<tag>
copier update --answers-file .copier-answers.cml-host.yml --vcs-ref=<tag>
```

Without `--vcs-ref` it takes the latest tag. The diff touches only the files
above; `CHANGELOG.md` says under `Upgrade` what a spoke must do beyond that.

Skipping `bootstrap.sh` leaves a project unmonitored with no error anywhere.
The rule that notices a host's *silence* lives on this stack, not on the
host. The backstop is `ProjectsUncovered`, regenerated on every bootstrap
run: it fires on any project the gateway counts telemetry for that is not
covered in `projects.yaml`, whichever signal that project sends.

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

In the host layer, answer `gpu=true`, which adds `compose.telemetry.gpu.yml`
and sets `GPU_METRICS=1` in `telemetry-host.env.example`, and include that file as
well. The agent config discovers the exporter by its Compose service label, so
nothing else changes.

A host without the NVIDIA container runtime cannot include the overlay at all
(`up` aborts with "could not select device driver"), so deploy tooling that
assembles its `-f` list from the host's `.env` needs a switch. Use
`GPU_METRICS=1` for it. None of the vendored files read that name; it is a
convention, so that one runbook covers every spoke.

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

Delete its pair from the `# COVERS:` line in
`config/grafana/alerting/projects.yaml`, re-run `bootstrap.sh` for any project
that remains, and commit the result. The one ProjectTelemetrySilent rule then
no longer checks it, and the coverage rule no longer counts it as covered.
On its machine, drop its entry from the host layer's `stacks` with
`copier update --answers-file .copier-answers.cml-host.yml --data stacks='...'`,
or the agent keeps shipping its containers.

## Limits

The healthchecks.io free tier is 20 checks. `bootstrap.sh` creates one per
project/environment (`watchdog`, which reports the other scheduled jobs), so
20 environments fit. Set `HC_JOBS` to create more.

## Verifying, from the monitoring host

```promql
count(telemetry_datapoints_total{project="<project>",env="<env>"})  # non-zero within ~2 min
count(container_start_time_seconds{project="<project>",name!=""})  # one per container
count({job="<service.name>"})                                      # app's own SDK metrics
```

If the first is still zero after five minutes, `ProjectTelemetrySilent`
will say so: it fires after 15 minutes without data, or about 20 minutes
after the last sample once a project has sent any, because `absent()` needs
the series to go stale first.
