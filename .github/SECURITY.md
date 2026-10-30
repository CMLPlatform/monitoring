# Security

<!-- The advisories link below works only once Settings > Code security >
     Private vulnerability reporting is on. -->

## Report a vulnerability

Report it privately, through
[a GitHub security advisory](https://github.com/CMLPlatform/monitoring/security/advisories/new).
Don't open a public issue or pull request for it: anyone can read those before there is a fix.

Please include:

- What the problem is and where it is: a file, a service or an image.
- Steps to reproduce it, or a proof of concept.
- The impact you expect, and the version you saw it in.

I acknowledge a report within 14 days, then tell you whether I can reproduce it and when I
expect a fix.

## Fixes and disclosure

A fix ships in a new release. When it is out, I publish the GitHub security advisory for
it, with a CVE where one applies, and credit you unless you'd rather not be named. The
CHANGELOG entry for that release links the advisory.

## Scope

This repository is a self-hosted stack, not a published package: Compose files, the
configuration of the services they run, and the scripts and templates that projects copy to
send it telemetry. It stores the logs, traces and metrics those projects send.

In scope:

- The Compose files, the service configuration in `config/` and the dashboards.
- How the stack exposes itself: the OTLP endpoint and its token check, Grafana sign-in, the
  Cloudflare Tunnel overlay and Access rule, and the guards that keep an exposed stack from
  starting with default settings.
- `bootstrap.sh`, `scripts/`, the spoke templates in `templates/` and the OpenTofu config in
  `infra/`.
- The CI and release workflows in `.github/workflows`.
- The image versions this repository pins, when the problem affects this stack.

Out of scope:

- A problem in Grafana, Loki, Tempo, Prometheus, the OpenTelemetry Collector or another
  upstream image that doesn't depend on how this repository configures it. Report it upstream.
- A host someone runs this stack on: its firewall, Docker setup or `.env` secrets.
