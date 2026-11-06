# ADR 0003: Spoke files reach repos as a two-layer Copier overlay

Date: 2026-11-06. Status: accepted. Amends the onboarding bullet of
[ADR 0002](0002-hub-and-spoke-observability.md).

## Context

ADR 0002 made onboarding a copy: `bootstrap.sh` printed `curl` commands and
checksums that vendored four files at a pinned tag, and each project pasted
six `.env` variables by hand. That works once. It does not tell a spoke that a
newer tag exists, and re-vendoring is the same manual checklist again, so
spokes drift: r9lab's `run_scheduled.sh` already lags the v0.5.0 fix.

It also tied the agent to a project: each agent shipped only its own Compose
project's containers, so a machine running two projects ran two agents, each
shipping the same host metrics and running its own GPU exporter. The GPU node
does that today (r9lab staging, and cmlops next).

CML project repos start from a Copier template (simonvanlierde/project-templates),
which stays free of anything CML-specific. Copier can apply further templates
to the same repo, each with its own answers file, and update each separately.

## Decision

The spoke files are a Copier template in this repo, the CML overlay, in two
layers. `copier.yml` sits at the root; its `layer` question sets
`_subdirectory` to `templates/spoke/project` or `templates/spoke/host`, so a
render holds one layer's files and nothing else from this repo.

- **The project layer**, in every project repo, answers in
  `.copier-answers.cml.yml`: `run_scheduled.sh` and `telemetry.env.example`
  (project, env, the SDK's endpoint and resource attributes, an optional
  contact address).
- **The host layer**, once per machine, in the repo that owns the machine,
  answers in `.copier-answers.cml-host.yml`: the Alloy agent, its config, the
  GPU overlay when `gpu` is true, and `telemetry-host.env.example`. Its
  `project` and `env` name the machine's owner.
- **One copy of each vendored file.** The files sit in `templates/spoke/<layer>/`
  at the path they take in a repo. They are not `.jinja` files: Copier copies
  them byte for byte, so the agent config is identical on every machine.
- **The `layer` answer must match the answers file.** A validator refuses
  the host layer without `--answers-file .copier-answers.cml-host.yml` and the
  project layer with it, since two layers in one answers file overwrite each
  other's answers.
- **A tag is still the deployable unit.** `bootstrap.sh` prints the `copier
  copy` commands pinned at the latest tag, and a later tag reaches each layer
  as `copier update --answers-file <its file>`: a diff in a PR.
- `just overlay-check` renders both layers, the host one with both `gpu`
  answers, checks the file lists and byte-identity, refuses bad names and a
  mismatched answers file, and validates each rendered agent config with the
  pinned Alloy. CI runs it.

### Which project a container belongs to

One agent now sees every container on the machine, so it has to know each
container's project and env. The host layer's `stacks` answer lists every
Compose project on the machine as `compose-project=project/env`, and renders
`deploy/alloy/projects.alloy`, two relabel components that config.alloy reads
(Alloy loads the directory as one config). A container of a Compose project
that `stacks` does not name is not shipped: its logs may hold data the hub
must not see, and its labels would be guesses.

- **Rejected: the Compose project name as `project`.** There is no env in it
  (r9lab runs `r9lab_prod` and `r9lab_staging`), and the dashboards and the
  keystone alert key on `project` and `env`.
- **Rejected: a label on every service** (`cml.project`, `cml.env`) set by
  each project. Every service in every repo would need it, a missed one
  ships nothing with no error, and the host's owner cannot see the miss.

### How an app's own telemetry reaches the hub

**Decision: straight to the hub's gateway, as before.** An app's OpenTelemetry
SDK sends to `OTEL_EXPORTER_OTLP_ENDPOINT` with the shared token, and sets
`project` and `env` itself (`OTEL_RESOURCE_ATTRIBUTES` in
`telemetry.env.example`). The host agent carries only what an app cannot
report about itself.

- The gateway stays the one place that stamps `department` and counts
  telemetry per project, so the keystone sees an app's traces even when the
  agent on its machine is down.
- Each project's app and agent fail separately: an agent restart drops no
  traces, and an app needs no network shared with another project's stack.
- **Rejected for now: a local OTLP receiver on the host agent.** It would
  hold the token in one place and buffer through hub outages, but every
  project's Compose stack would have to join an external network the host
  layer owns, the agent would have to keep each sender's resource
  attributes intact, and its failure would silence every app on the
  machine at once. Revisit it with per-project tokens (ADR 0002's trigger),
  or when a machine may only reach the hub through one process.

### What bootstrap.sh and the alerts key on

On project and env, not the machine. `bootstrap.sh <project> <env>` and the
`ProjectTelemetrySilent` and `ProjectsUncovered` rules are unchanged:

- A project's containers carry its project and env through `stacks`, and
  its app's own telemetry carries them through the SDK, so the gateway counts
  it per project as before.
- Host-level series (node metrics, the GPU, the agent's own health) carry
  the owner's project and env, so the owner's keystone also covers the agent.
  `host_name` stays a label for the dashboards, never an alert key.
- If the agent dies, every project on that machine whose only telemetry is
  the agent goes silent and fires on its own. A project with an instrumented
  app keeps counting through the gateway, so the agent's loss shows on the
  owner's rule and on the dashboards' host panels.
- A `stacks` entry for a project nobody bootstrapped fires
  `ProjectsUncovered`, the same as before.

## Alternatives considered

- **Keep the `curl` checklist:** no update path, as above.
- **Each layer as its own template in a subdirectory**
  (`gh:CMLPlatform/monitoring/templates/host`): Copier reads `copier.yml` only
  at the root of a git repo, and a local subdirectory path renders without
  version control, so it could never be updated. Two templates would need two
  repos.
- **One layer, as first built:** keeps two agents on every shared machine.
- **The overlay inside project-templates:** puts CML's hub endpoint and
  conventions into a personal template ruled to stay CML-free.

## Consequences

- **Breaking for hand-vendored spokes:** config.alloy no longer runs alone;
  it needs the `projects.alloy` the host layer renders, and the agent loads
  the `deploy/alloy/` directory. A spoke that still vendors by `curl` keeps
  working at its old tag and moves with one `copier copy` per layer.
- The repo that owns a machine carries the host layer. When a stack moves
  to another machine, its entry moves to that machine's `stacks`.
- Applying a layer needs Copier on the machine that edits the repo, not on
  the spoke.
