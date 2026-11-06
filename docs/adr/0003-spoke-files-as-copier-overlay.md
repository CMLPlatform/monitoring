# ADR 0003: Spoke files reach projects as a Copier overlay

Date: 2026-11-06. Status: accepted. Amends the onboarding bullet of
[ADR 0002](0002-hub-and-spoke-observability.md).

## Context

ADR 0002 made onboarding a copy: `bootstrap.sh` printed `curl` commands and
checksums that vendored four files at a pinned tag, and each project pasted
six `.env` variables by hand. That works once. It does not tell a spoke that a
newer tag exists, and re-vendoring is the same manual checklist again, so
spokes drift: r9lab's `run_scheduled.sh` already lags the v0.5.0 fix.

CML project repos start from a Copier template (simonvanlierde/project-templates),
which stays free of anything CML-specific. Copier can apply a second template
to the same repo with its own answers file, and update each one separately.

## Decision

The spoke files are a Copier template in this repo, the CML overlay.
`copier.yml` sits at the root and renders `templates/spoke/` only; the overlay
writes `.copier-answers.cml.yml`, so it never shares answers with the
project's base template.

- **One copy of each file.** The vendored files moved to `templates/spoke/` at
  the path they take in a project (`deploy/alloy/config.alloy`,
  `scripts/run_scheduled.sh`, the two compose overlays at the root). They are
  not `.jinja` files: Copier copies them byte for byte, so the agent config
  stays identical on every host, and the lint and validate recipes check the
  same files a project receives.
- **The answers are what differs per project:** `project` and `env` (with
  `bootstrap.sh`'s validation), `gpu` (renders `compose.telemetry.gpu.yml`
  only when true), the hub's OTLP endpoint, and an optional contact address.
  They render into `.env.telemetry.example`. No secret is asked for or written.
- **A tag is still the deployable unit.** `bootstrap.sh` prints `copier copy`
  pinned at the latest tag, and a later tag reaches a spoke as
  `copier update --answers-file .copier-answers.cml.yml`: a diff in a PR,
  reviewed like any other.
- `just overlay-check` renders the overlay with both `gpu` answers and fails
  on a missing or extra file, a vendored file that differs from its source, or
  a project name `bootstrap.sh` would refuse. CI runs it.

## Alternatives considered

- **Keep the `curl` checklist:** no update path, as above.
- **Symlinks from a template folder to the old paths:** one copy too, but the
  real files would sit at paths no project uses, and a symlink in a Copier
  template is resolved at render time on whatever OS runs it.
- **The overlay inside project-templates:** puts CML's hub endpoint and
  conventions into a personal template ruled to stay CML-free.

## Consequences

- The raw URLs of the vendored files changed with the move. A spoke that still
  vendors by `curl` keeps working at its old tag and moves to the overlay
  with one `copier copy`, after which its hand-vendored files are replaced by
  the same files.
- Applying the overlay needs Copier on the machine that edits the project's
  repo, not on the project host.
