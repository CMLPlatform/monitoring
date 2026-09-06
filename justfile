set dotenv-load

# Stateful services. Their volumes are <project>_<service>_data, which is how
# _backup and _restore find them for whichever compose project they act on.
stateful := "grafana prometheus loki tempo"

# Helper and lint images, pinned once. `lint` pulls the lint set in parallel
# up front: serial first-use pulls are most of a cold run.
alpine := "alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
jq := "ghcr.io/jqlang/jq:1.8.1"
yamllint := "pipelinecomponents/yamllint:0.35.13"
yamlfmt := "ghcr.io/google/yamlfmt:0.17.2"
actionlint := "rhysd/actionlint:1.7.12"
shellcheck := "koalaman/shellcheck:v0.11.0"
ruff := "ghcr.io/astral-sh/ruff:0.14.2"
tofu := "ghcr.io/opentofu/opentofu:1.12.3"
gitleaks := "zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"
alloy := "grafana/alloy:v1.18.1@sha256:0f4434c92b3e6cdac38bb129b344e1790c246f7b6e2eaffcc16a5fa363240e33"
lint_images := jq + " " + yamllint + " " + yamlfmt + " " + actionlint + " " + shellcheck + " " + ruff + " " + tofu + " " + gitleaks + " " + alloy

# `demo` and `smoke` each bring up a throwaway copy of the core stack, so both
# run under their own compose project and their own Grafana port (see
# compose.sandbox.yml). Neither can adopt, recreate or delete the containers and
# volumes of a stack already running on this host: `just demo` on the production
# box spins up its own Grafana next to the real one instead of joining it. The
# explicit -f list also keeps a host's COMPOSE_FILE (tunnel) out of both.
demo_project := "monitoring-demo"
demo_port := env("DEMO_PORT", "3002")
compose_demo := "SANDBOX_PORT=" + demo_port + " docker compose -p " + demo_project + " -f compose.yml -f compose.demo.yml -f compose.sandbox.yml"

# What compose will actually name the project for the up-paths, so the queue
# volume gets chowned where the collector will look for it, and backup/restore
# mount the volumes the running stack uses.
core_project := env("COMPOSE_PROJECT_NAME", "monitoring")

# Same isolation for smoke, on its own project and port so a smoke run and a
# demo stack can also coexist. The smoke stack boots in production shape:
# Grafana with JWT auth on (the Cloudflare Access path, otherwise only ever
# schema-checked) and fixed notification URLs so the contact-point assertion
# can check exact values instead of "not empty". The team domain has a dot,
# which no real Zero Trust team name can, so the JWK URL can never resolve to
# a team someone registers.
smoke_project := "monitoring-smoke"
smoke_port := env("SMOKE_PORT", "3001")
smoke_env := "SANDBOX_PORT=" + smoke_port + " GRAFANA_JWT_AUTH=true CF_ACCESS_TEAM_DOMAIN=smoke.invalid CF_ACCESS_AUD=smoke ALERT_WEBHOOK_URL=https://smoke.invalid/alerts HEARTBEAT_URL=https://smoke.invalid/heartbeat"
compose_smoke := smoke_env + " docker compose -p " + smoke_project + " -f compose.yml -f compose.sandbox.yml"

# dashboards/*.json as the paths they get when mounted at /dashboards. 2>/dev/null
# so an empty dashboards/ doesn't abort every recipe in this file, including the
# teardown ones; `lint` refuses the empty list instead.
dash_paths := `ls dashboards/*.json 2>/dev/null | sed 's|^dashboards|/dashboards|' | tr '\n' ' '`

# List the recipes.
default:
    @just --list

# The collector's queue volume must be writable by the image's uid 10001, but
# a fresh named volume is root-owned and the image is distroless (no chown at
# startup possible). Idempotent, so every up-path just runs it. Takes the
# project name because smoke brings the stack up under a different one.
_queue-volume project:
    @docker volume create {{project}}_otel_queue > /dev/null
    @docker run --rm --network none -v {{project}}_otel_queue:/q {{alpine}} chown 10001:10001 /q

# Overlays are host config: COMPOSE_FILE in .env names the file set (see
# .env.example), and every recipe here (up, down, logs, ps, backup) acts on
# that same set. With the tunnel overlay active, this refuses to start until the
# exposure guards pass.
# Start the stack (Grafana at http://localhost:3000).
up: (_queue-volume core_project) _guard-if-exposed
    docker compose up -d

# The exposure guards, but only when the tunnel overlay is in play. Shared by
# every recipe that can put a service back on the tunnel.
_guard-if-exposed:
    @case "${COMPOSE_FILE:-}" in *compose.tunnel.yml*) just _expose-guards;; esac

# Refuses to expose the stack with the documented default credentials.
_expose-guards:
    @[ "${OTLP_AUTH_TOKEN:-}" != "local-dev-token" ] || { echo "error: OTLP_AUTH_TOKEN is still the local default; generate one (openssl rand -hex 32) before exposing ingestion" >&2; exit 1; }
    @[ "${GRAFANA_ADMIN_PASSWORD:-}" != "change-me" ] || { echo "error: GRAFANA_ADMIN_PASSWORD is still the documented default; change it before exposing Grafana" >&2; exit 1; }
    @case "${GRAFANA_ROOT_URL:-}" in https://*) ;; *) echo "error: GRAFANA_ROOT_URL must be the https:// tunnel hostname (got '${GRAFANA_ROOT_URL:-}'); every absolute URL Grafana generates comes from it" >&2; exit 1;; esac
    @[ "${GRAFANA_COOKIE_SECURE:-false}" = "true" ] || { echo "error: GRAFANA_COOKIE_SECURE must be true when Grafana is served over HTTPS; set it in .env" >&2; exit 1; }
    @[ "${GRAFANA_JWT_AUTH:-false}" != "true" ] || { [ -n "${CF_ACCESS_TEAM_DOMAIN:-}" ] && [ -n "${CF_ACCESS_AUD:-}" ]; } || { echo "error: GRAFANA_JWT_AUTH=true needs CF_ACCESS_TEAM_DOMAIN and CF_ACCESS_AUD in .env (cd infra && tofu output -raw grafana_access_aud)" >&2; exit 1; }
    @[ -n "${HEARTBEAT_URL:-}" ] || echo "WARNING: HEARTBEAT_URL is empty; the stack goes live without a dead-man's switch" >&2
    @[ -n "${ALERT_WEBHOOK_URL:-}" ] || { echo "error: ALERT_WEBHOOK_URL is empty; every alert would fire into an empty webhook URL and be dropped. The heartbeat keeps pinging either way, so this failure looks healthy from the outside. Set it, or comment out this guard" >&2; exit 1; }

# Stop the stack; volumes stay.
down:
    docker compose down --remove-orphans

# See compose.demo.yml; watch it arrive at http://localhost:3002 (DEMO_PORT):
# its own Grafana, not the one `just up` serves on :3000.
# Core stack plus a demo telemetry source, isolated from any running stack.
demo: (_queue-volume demo_project)
    {{compose_demo}} up -d --build

# Removes only the demo services; the demo project's own core stack keeps
# running. `just demo-destroy` takes the whole thing down.
# Stop the demo telemetry source.
demo-down:
    {{compose_demo}} rm -sf demo-api demo-load

# Safe: -p scopes it to the demo project, so it cannot touch a real stack on
# the same host.
# Tear down the whole demo stack and its throwaway volumes.
demo-destroy:
    {{compose_demo}} down --remove-orphans --volumes

# Follow logs, optionally of one service.
logs service="":
    docker compose logs -f {{service}}

# Container status of the stack.
ps:
    docker compose ps

# Targets the COMPOSE_FILE set; demo services are recreated with `just demo`.
# Restart one service.
restart service: _guard-if-exposed
    docker compose restart {{service}}

# Pull the pinned images.
pull:
    docker compose pull

# Tail a service's logs as JSON, decoded. Useful before Grafana is set up.
tail service:
    docker compose logs -f --no-log-prefix {{service}} | jq -R 'fromjson? // .'

# Every check in this file runs in a container: no host installs, no network.
# `lint` is the static half in small tool images; `validate` runs the stack's
# own images against its configs. Both are seconds warm, so the pre-push hook
# (`just hooks`) runs both; CI puts `lint` on its own job so a lint failure
# never waits on the stack images, which the smoke job pulls anyway.
# Validate every config in the repo.
check: lint validate

# Static checks in tool images (~280 MB cold, seconds warm).
lint:
    @printf '%s\n' {{lint_images}} | xargs -P 8 -n 1 docker pull -q >/dev/null
    # `-f compose.yml` on the first line, not the host's COMPOSE_FILE: on a
    # tunnel host that would validate the tunnel set with no dummy token, so
    # `just lint` would mean something different there than in CI.
    docker compose -f compose.yml config -q
    CLOUDFLARE_TUNNEL_TOKEN=dummy docker compose -f compose.yml -f compose.tunnel.yml config -q
    {{compose_demo}} config -q
    # Also the JWT interpolation in compose.yml: compose_smoke turns it on.
    {{compose_smoke}} config -q
    # The spoke overlays every project host layers onto its own compose.yml; a
    # bad interpolation or a network they forget to declare otherwise first
    # fails on a client machine, after vendoring.
    ENVIRONMENT=dummy PROJECT=dummy COMPOSE_PROJECT_NAME=dummy OTEL_EXPORTER_OTLP_ENDPOINT=https://dummy OTLP_AUTH_TOKEN=dummy docker compose -f templates/compose.telemetry.yml -f templates/compose.telemetry.gpu.yml config -q
    # The exposure guards, both ways: a fully set .env must pass, and each
    # documented default must be refused on its own. Nothing else runs them:
    # CI never sets COMPOSE_FILE to the tunnel overlay.
    @good="OTLP_AUTH_TOKEN=t GRAFANA_ADMIN_PASSWORD=p GRAFANA_ROOT_URL=https://g.example GRAFANA_COOKIE_SECURE=true GRAFANA_JWT_AUTH=true CF_ACCESS_TEAM_DOMAIN=d CF_ACCESS_AUD=a HEARTBEAT_URL=https://h ALERT_WEBHOOK_URL=https://w"; \
      env $good just _expose-guards || { echo "error: exposure guards rejected a fully set environment" >&2; exit 1; }; \
      for bad in OTLP_AUTH_TOKEN=local-dev-token GRAFANA_ADMIN_PASSWORD=change-me GRAFANA_ROOT_URL=http://g.example GRAFANA_COOKIE_SECURE=false CF_ACCESS_AUD= ALERT_WEBHOOK_URL=; do \
        ! env $good $bad just _expose-guards 2>/dev/null || { echo "error: exposure guards accepted $bad" >&2; exit 1; }; \
      done
    # line-length at 120, not the default 80: digest-pinned image refs need
    # ~130 but count as non-breakable mappings. The rendered project-*/coverage
    # rules are ignored: bootstrap.sh writes them, and their expr lines grow
    # with every onboarded project. The templates they come from are checked
    # by rendering them through bootstrap.sh itself into a scratch dir, so a
    # template edit Grafana would reject fails here and not on the next
    # onboarding.
    docker run --rm --network none -v .:/code:ro {{yamllint}} yamllint -d '{extends: relaxed, rules: {line-length: {max: 120, allow-non-breakable-inline-mappings: true}}, ignore: [.git/, backups/, infra/.terraform/, config/grafana/alerting/project-*.yaml, config/grafana/alerting/coverage.yaml]}' .
    @d=$(mktemp -d) && BOOTSTRAP_OUT_DIR="$d" ./bootstrap.sh dummy dummy >/dev/null && docker run --rm --network none -v "$d":/code:ro {{yamllint}} yamllint -d '{extends: relaxed, rules: {line-length: disable}}' .; rc=$?; rm -rf "$d"; exit $rc
    docker run --rm --network none -v .:/repo:ro -w /repo {{actionlint}} -color
    docker run --rm --network none -v .:/mnt:ro {{shellcheck}} bootstrap.sh scripts/smoke.sh templates/run_scheduled.sh infra/generate-imports.sh
    docker run --rm --network none -v ./demo:/demo:ro {{ruff}} check --no-cache /demo
    docker run --rm --network none -v ./demo:/demo:ro {{ruff}} format --check --no-cache /demo
    # Formatting is enforced, not just linted: `just fmt` is the fix.
    docker run --rm --network none -v .:/code:ro -w /code {{yamlfmt}} -lint .
    docker run --rm --network none -v ./infra:/infra:ro -w /infra {{tofu}} fmt -check
    # Dashboards: valid JSON, and every datasource they name is one that
    # datasources.yaml provisions (plus Grafana's built-in). A typo here
    # provisions fine and renders empty panels.
    @[ -n "{{dash_paths}}" ] || { echo "error: no dashboards/*.json to check" >&2; exit 1; }
    docker run --rm --network none -v ./dashboards:/dashboards:ro {{jq}} empty {{dash_paths}}
    @bad=$(docker run --rm --network none -v ./dashboards:/dashboards:ro {{jq}} -r '.. | objects | select(has("datasource")) | .datasource | (if type == "object" then .uid else . end) | strings' {{dash_paths}} | sort -u | grep -vxF "$(sed -n 's/^ *uid: *//p' config/grafana/datasources.yaml; echo grafana)"); \
      [ -z "$bad" ] || { echo "error: dashboards reference datasource uids that are not provisioned:" $bad >&2; exit 1; }
    # Secrets that reached git history. Scans commits, not the working tree, so
    # it sees exactly what is in the repo and never the gitignored .env. A
    # working-tree scan flags .env's real tokens and fails on every dev machine.
    # Needs full history: a shallow CI clone has one commit and passes vacuously.
    docker run --rm --network none -v .:/repo:ro {{gitleaks}} git --redact --no-banner /repo
    # The one config vendored verbatim onto every project host; a syntax error
    # here otherwise first surfaces as a crash-looping agent on a client machine.
    # Image ref matches templates/compose.telemetry.yml; keep them in step. In
    # `lint`, not `validate`: the smoke job pulls nothing else this size.
    docker run --rm --network none -v ./templates/alloy/config.alloy:/etc/alloy/config.alloy:ro -e COMPOSE_PROJECT_NAME=dummy -e ENVIRONMENT=dummy -e PROJECT=dummy -e OTEL_EXPORTER_OTLP_ENDPOINT=https://dummy -e OTLP_AUTH_TOKEN=dummy -e TELEMETRY_EDGE_KEY= {{alloy}} validate /etc/alloy/config.alloy

# Image ref of one compose.yml service, so the validators below can't drift
# from the versions the stack runs. (`config --images <svc>` also lists the
# service's dependencies, hence the json route.)
_image service:
    @docker compose -f compose.yml config --format json | docker run --rm -i {{jq}} -er '.services["{{service}}"].image // error("no service {{service}} in compose.yml")'

# The validators run in the images the stack itself runs. ~290 MB cold, but
# the smoke job has them anyway.
# Run each config through the binary that will load it.
validate:
    docker run --rm --network none -v ./config/prometheus.yaml:/etc/prometheus/prometheus.yaml:ro --entrypoint promtool $(just _image prometheus) check config /etc/prometheus/prometheus.yaml
    docker run --rm --network none -e OTLP_AUTH_TOKEN=dummy -e DEPARTMENT=dummy -v ./config/otel-collector.yaml:/etc/otelcol/config.yaml:ro $(just _image otel-collector) validate --config=/etc/otelcol/config.yaml
    docker run --rm --network none -v ./config/loki.yaml:/etc/loki/loki.yaml:ro $(just _image loki) -config.file=/etc/loki/loki.yaml -verify-config
    docker run --rm --network none -v ./config/tempo.yaml:/etc/tempo/tempo.yaml:ro $(just _image tempo) -config.file=/etc/tempo/tempo.yaml -config.verify=true

# Runs against a copy of the sources only: state and tfvars never enter the
# container, which needs network access to fetch the provider.
# Full OpenTofu validation (downloads the provider, so not part of `check`).
infra-validate:
    @d=$(mktemp -d) && cp infra/main.tf infra/.terraform.lock.hcl "$d"/ && docker run --rm --entrypoint sh -v "$d":/src:ro {{tofu}} -c 'mkdir /work && cp /src/main.tf /src/.terraform.lock.hcl /work && cd /work && tofu init -backend=false -input=false >/dev/null && tofu validate'; rc=$?; rm -rf "$d"; exit $rc

# Same container-only rule as `lint`; --user so the rewritten files stay yours.
# Format YAML in place.
fmt:
    docker run --rm --network none --user "$(id -u):$(id -g)" -v .:/code -w /code {{yamlfmt}} .

# Install the git hooks: gitleaks on commit, `just check` on push (see .pre-commit-config.yaml).
hooks:
    prek install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push

# The tarball is mode 0600: it contains the Grafana DB and webhook secrets, so
# copy it off-host and keep it private.
# Snapshot all stateful volumes to backups/<timestamp>.tar.gz.
backup: (_backup core_project "backups")

# gzip -1: the stack is paused for as long as the tar runs, and the TSDB
# chunks are already compressed, so the higher levels cost time for nothing.
# Services are paused during the copy and unpaused unconditionally afterwards:
# `pause` is per-container and can fail halfway, so an unpause reached only on
# success would leave the stack frozen. A failed unpause fails the recipe for
# the same reason: a green exit with the stack still SIGSTOPped is worse.
_backup project dir:
    mkdir -p {{dir}}
    @-docker compose -p {{project}} unpause {{stateful}} >/dev/null 2>&1
    @rc=0; m=$(for s in {{stateful}}; do printf -- '-v {{project}}_%s_data:/data/%s ' $s $s; done); docker compose -p {{project}} pause {{stateful}} && docker run --rm --network none $m -v {{absolute_path(dir)}}:/backups {{alpine}} sh -c 'umask 077 && tar cf - -C /data . | gzip -1 > /backups/monitoring-$(date +%Y%m%d-%H%M%S).tar.gz' || rc=$?; docker compose -p {{project}} unpause {{stateful}} || { echo "error: unpause failed; the stack is still paused" >&2; rc=1; }; exit $rc
    @ls -lh {{dir}}/ | tail -1

# Restore a backup tarball into the volumes (stops the stack; wipes current state).
restore file: (_restore core_project file "backups")
    @echo "Restored {{file}}. Run 'just up' to start the stack."

# The wipe is unrecoverable, so the current state is snapshotted first: if the
# extract dies halfway (full disk, wrong volume set) the volumes are left
# partial, and <dir>/pre-restore-*.tar.gz is the only way back.
_restore project file dir:
    @[ -f "{{file}}" ] || { echo "error: {{file}} not found" >&2; exit 1; }
    docker run --rm --network none -v {{absolute_path(file)}}:/backup.tar.gz:ro {{alpine}} tar tzf /backup.tar.gz > /dev/null
    docker compose -p {{project}} down --remove-orphans
    mkdir -p {{dir}}
    m=$(for s in {{stateful}}; do printf -- '-v {{project}}_%s_data:/data/%s ' $s $s; done); docker run --rm --network none $m -v {{absolute_path(dir)}}:/backups {{alpine}} sh -c 'umask 077 && tar czf /backups/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz -C /data .'
    m=$(for s in {{stateful}}; do printf -- '-v {{project}}_%s_data:/data/%s ' $s $s; done); docker run --rm --network none $m -v {{absolute_path(file)}}:/backup.tar.gz:ro {{alpine}} sh -c 'for d in /data/*; do find "$d" -mindepth 1 -delete; done && tar xzf /backup.tar.gz -C /data'

# The only rehearsal of the one recipe that wipes state: backs up the smoke
# stack's volumes, restores them, and asserts Grafana's database came back.
# Needs a booted smoke stack (`just smoke`); `just smoke-down` cleans up after.
# Not in CI: it is a rehearsal for an operator, and 35s per push buys nothing a
# run after touching _backup/_restore does not.
# Round-trip backup and restore on the smoke stack.
restore-check:
    @d=$(mktemp -d) && just _backup {{smoke_project}} "$d" && f=$(ls "$d"/monitoring-*.tar.gz) && just _restore {{smoke_project}} "$f" "$d" && docker run --rm --network none -v {{smoke_project}}_grafana_data:/g:ro {{alpine}} test -s /g/grafana.db && echo "Backup round-trip ok"; rc=$?; rm -rf "$d"; exit $rc

# `--wait` does the readiness and crash-loop work: it blocks on the grafana and
# prometheus healthchecks in compose.yml and fails if any container exits, so
# there is no poll loop or `ps --status=exited` check to hand-roll here.
# A service with no healthcheck of its own (otel-collector, loki, tempo) still
# fails the wait while it is restarting, so a crash-looping collector is caught.
# That costs the full --wait-timeout to report, where an explicit exit check
# failed immediately. What `--wait` cannot see is everything that lands after
# /api/health answers: provisioning, scrapes, the data paths. scripts/smoke.sh
# asserts those.
# Boot an isolated copy of the core stack and assert it works end to end.
smoke: (_queue-volume smoke_project)
    {{compose_smoke}} up -d --wait --wait-timeout 120
    {{smoke_env}} SMOKE_URL=http://localhost:{{smoke_port}} SMOKE_PROJECT={{smoke_project}} scripts/smoke.sh

# Logs from the smoke stack (its own project, so `just logs` will not show it).
smoke-logs:
    {{compose_smoke}} logs --no-color --tail=200

# Safe: -p scopes it to the smoke project, so it cannot touch a real stack on
# the same host.
# Tear down the smoke stack and its throwaway volumes (-t 1: nothing in it is worth a graceful stop).
smoke-down:
    {{compose_smoke}} down --remove-orphans --volumes -t 1
