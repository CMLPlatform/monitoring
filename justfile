set dotenv-load

# Stateful services; their volumes are <project>_<service>_data.
stateful := "grafana prometheus loki tempo"

# Helper and lint images, pinned once.
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

# `demo` and `smoke` each run a throwaway copy of the core stack under their own
# compose project and Grafana port (compose.sandbox.yml), so neither can touch a
# stack already running on this host. The explicit -f list keeps the host's
# COMPOSE_FILE out of both.
demo_project := "monitoring-demo"
demo_port := env("DEMO_PORT", "3002")
compose_demo := "SANDBOX_PORT=" + demo_port + " docker compose -p " + demo_project + " -f compose.yml -f compose.demo.yml -f compose.sandbox.yml"

# The project name compose will use, so the queue volume and backups target
# the running stack's volumes.
core_project := env("COMPOSE_PROJECT_NAME", "monitoring")

# The smoke stack boots in production shape: JWT auth on and fixed notification
# URLs, so smoke.sh can assert exact values. The team domain has a dot, which no
# real Zero Trust team name can, so the JWK URL can never resolve to a team
# someone registers.
smoke_project := "monitoring-smoke"
smoke_port := env("SMOKE_PORT", "3001")
smoke_env := "SANDBOX_PORT=" + smoke_port + " GRAFANA_JWT_AUTH=true CF_ACCESS_TEAM_DOMAIN=smoke.invalid CF_ACCESS_AUD=smoke ALERT_WEBHOOK_URL=https://smoke.invalid/alerts HEARTBEAT_URL=https://smoke.invalid/heartbeat"
compose_smoke := smoke_env + " docker compose -p " + smoke_project + " -f compose.yml -f compose.sandbox.yml"

# dashboards/*.json as mounted at /dashboards. 2>/dev/null so an empty
# dashboards/ doesn't abort every recipe; `lint` refuses the empty list instead.
dash_paths := `ls dashboards/*.json 2>/dev/null | sed 's|^dashboards|/dashboards|' | tr '\n' ' '`

# List the recipes.
default:
    @just --list

# A fresh named volume is root-owned and the collector image is distroless, so
# chown its queue volume to uid 10001 here. Idempotent; every up-path runs it.
_queue-volume project:
    @docker volume create {{project}}_otel_queue > /dev/null
    @docker run --rm --network none -v {{project}}_otel_queue:/q {{alpine}} chown 10001:10001 /q

# COMPOSE_FILE in .env names the overlays. With the tunnel overlay active, this
# refuses to start until the exposure guards pass.
# Start the stack (Grafana at http://localhost:3000).
up: (_queue-volume core_project) _guard-if-exposed
    docker compose up -d

# The exposure guards, only when the tunnel overlay is in play.
_guard-if-exposed:
    @case "${COMPOSE_FILE:-}" in *compose.tunnel.yml*) just _expose-guards;; esac

# Refuses to expose the stack with the documented default credentials or with
# secret files other local users can read.
_expose-guards:
    @[ "${OTLP_AUTH_TOKEN:-}" != "local-dev-token" ] || { echo "error: OTLP_AUTH_TOKEN is still the local default; generate one (openssl rand -hex 32) before exposing ingestion" >&2; exit 1; }
    @[ "${GRAFANA_ADMIN_PASSWORD:-}" != "change-me" ] || { echo "error: GRAFANA_ADMIN_PASSWORD is still the documented default; change it before exposing Grafana" >&2; exit 1; }
    @case "${GRAFANA_ROOT_URL:-}" in https://*) ;; *) echo "error: GRAFANA_ROOT_URL must be the https:// tunnel hostname (got '${GRAFANA_ROOT_URL:-}'); every absolute URL Grafana generates comes from it" >&2; exit 1;; esac
    @[ "${GRAFANA_COOKIE_SECURE:-false}" = "true" ] || { echo "error: GRAFANA_COOKIE_SECURE must be true when Grafana is served over HTTPS; set it in .env" >&2; exit 1; }
    @[ "${GRAFANA_JWT_AUTH:-false}" != "true" ] || { [ -n "${CF_ACCESS_TEAM_DOMAIN:-}" ] && [ -n "${CF_ACCESS_AUD:-}" ]; } || { echo "error: GRAFANA_JWT_AUTH=true needs CF_ACCESS_TEAM_DOMAIN and CF_ACCESS_AUD in .env (cd infra && tofu output -raw grafana_access_aud)" >&2; exit 1; }
    @[ -n "${HEARTBEAT_URL:-}" ] || echo "WARNING: HEARTBEAT_URL is empty; the stack goes live without a dead-man's switch" >&2
    @for f in .env infra/terraform.tfvars infra/terraform.tfstate infra/terraform.tfstate.backup; do [ ! -e "$f" ] || case "$(stat -c %a "$f")" in *00) ;; *) echo "error: $f is readable by other users (mode $(stat -c %a "$f")); it holds live secrets, run: chmod 600 $f" >&2; exit 1;; esac; done
    @[ -n "${ALERT_WEBHOOK_URL:-}" ] || { echo "error: ALERT_WEBHOOK_URL is empty; every alert would fire into an empty webhook URL and be dropped. The heartbeat keeps pinging either way, so this failure looks healthy from the outside. Set it, or comment out this guard" >&2; exit 1; }

# Stop the stack; volumes stay.
down:
    docker compose down --remove-orphans

# Core stack plus a demo telemetry source, isolated from any running stack (:3002).
demo: (_queue-volume demo_project)
    {{compose_demo}} up -d --build

# Stop the demo telemetry source; the demo project's core stack keeps running.
demo-down:
    {{compose_demo}} rm -sf demo-api demo-load

# Tear down the whole demo stack and its throwaway volumes.
demo-destroy:
    {{compose_demo}} down --remove-orphans --volumes

# Follow logs, optionally of one service.
logs service="":
    docker compose logs -f {{service}}

# Container status of the stack.
ps:
    docker compose ps

# Restart one service.
restart service: _guard-if-exposed
    docker compose restart {{service}}

# Pull the pinned images.
pull:
    docker compose pull

# Tail a service's logs as JSON, decoded. Useful before Grafana is set up.
tail service:
    docker compose logs -f --no-log-prefix {{service}} | jq -R 'fromjson? // .'

# Every check runs in a container: no host installs, no network.
# Validate every config in the repo.
check: lint validate

# Static checks in tool images (~280 MB cold, seconds warm).
lint:
    @printf '%s\n' {{lint_images}} | xargs -P 8 -n 1 docker pull -q >/dev/null
    # Explicit -f, not the host's COMPOSE_FILE, so lint means the same here as in CI.
    docker compose -f compose.yml config -q
    CLOUDFLARE_TUNNEL_TOKEN=dummy docker compose -f compose.yml -f compose.tunnel.yml config -q
    {{compose_demo}} config -q
    # compose_smoke turns the JWT interpolation on.
    {{compose_smoke}} config -q
    # The spoke overlays, which otherwise first fail on a project host after vendoring.
    ENVIRONMENT=dummy PROJECT=dummy COMPOSE_PROJECT_NAME=dummy OTEL_EXPORTER_OTLP_ENDPOINT=https://dummy OTLP_AUTH_TOKEN=dummy docker compose -f templates/compose.telemetry.yml -f templates/compose.telemetry.gpu.yml config -q
    # The exposure guards, both ways: a fully set .env passes, and each
    # documented default is refused on its own.
    @good="OTLP_AUTH_TOKEN=t GRAFANA_ADMIN_PASSWORD=p GRAFANA_ROOT_URL=https://g.example GRAFANA_COOKIE_SECURE=true GRAFANA_JWT_AUTH=true CF_ACCESS_TEAM_DOMAIN=d CF_ACCESS_AUD=a HEARTBEAT_URL=https://h ALERT_WEBHOOK_URL=https://w"; \
      env $good just _expose-guards || { echo "error: exposure guards rejected a fully set environment" >&2; exit 1; }; \
      for bad in OTLP_AUTH_TOKEN=local-dev-token GRAFANA_ADMIN_PASSWORD=change-me GRAFANA_ROOT_URL=http://g.example GRAFANA_COOKIE_SECURE=false CF_ACCESS_AUD= ALERT_WEBHOOK_URL=; do \
        ! env $good $bad just _expose-guards 2>/dev/null || { echo "error: exposure guards accepted $bad" >&2; exit 1; }; \
      done
    # The rendered project-*/coverage rules are skipped (their expr lines grow
    # with every project); their templates are checked by rendering them into
    # a scratch dir instead.
    docker run --rm --network none -v .:/code:ro {{yamllint}} yamllint -d '{extends: relaxed, rules: {line-length: {max: 120, allow-non-breakable-inline-mappings: true}}, ignore: [.git/, backups/, infra/.terraform/, config/grafana/alerting/project-*.yaml, config/grafana/alerting/coverage.yaml]}' .
    @d=$(mktemp -d) && BOOTSTRAP_OUT_DIR="$d" ./bootstrap.sh dummy dummy >/dev/null && docker run --rm --network none -v "$d":/code:ro {{yamllint}} yamllint -d '{extends: relaxed, rules: {line-length: disable}}' .; rc=$?; rm -rf "$d"; exit $rc
    docker run --rm --network none -v .:/repo:ro -w /repo {{actionlint}} -color
    docker run --rm --network none -v .:/mnt:ro {{shellcheck}} bootstrap.sh scripts/smoke.sh templates/run_scheduled.sh infra/generate-imports.sh
    docker run --rm --network none -v ./demo:/demo:ro {{ruff}} check --no-cache /demo
    docker run --rm --network none -v ./demo:/demo:ro {{ruff}} format --check --no-cache /demo
    # `just fmt` is the fix.
    docker run --rm --network none -v .:/code:ro -w /code {{yamlfmt}} -lint .
    docker run --rm --network none -v ./infra:/infra:ro -w /infra {{tofu}} fmt -check
    # Dashboards: valid JSON, and every datasource uid they name is provisioned.
    # A typo provisions fine and renders empty panels.
    @[ -n "{{dash_paths}}" ] || { echo "error: no dashboards/*.json to check" >&2; exit 1; }
    docker run --rm --network none -v ./dashboards:/dashboards:ro {{jq}} empty {{dash_paths}}
    @bad=$(docker run --rm --network none -v ./dashboards:/dashboards:ro {{jq}} -r '.. | objects | select(has("datasource")) | .datasource | (if type == "object" then .uid else . end) | strings' {{dash_paths}} | sort -u | grep -vxF "$(sed -n 's/^ *uid: *//p' config/grafana/datasources.yaml; echo grafana)"); \
      [ -z "$bad" ] || { echo "error: dashboards reference datasource uids that are not provisioned:" $bad >&2; exit 1; }
    # Secrets in git history. Scans commits, not the working tree, so the
    # gitignored .env never trips it. Needs full history (see ci.yml).
    docker run --rm --network none -v .:/repo:ro {{gitleaks}} git --redact --no-banner /repo
    # The agent config every project host vendors. Image ref matches
    # templates/compose.telemetry.yml; keep them in step.
    docker run --rm --network none -v ./templates/alloy/config.alloy:/etc/alloy/config.alloy:ro -e COMPOSE_PROJECT_NAME=dummy -e ENVIRONMENT=dummy -e PROJECT=dummy -e OTEL_EXPORTER_OTLP_ENDPOINT=https://dummy -e OTLP_AUTH_TOKEN=dummy -e TELEMETRY_EDGE_KEY= {{alloy}} validate /etc/alloy/config.alloy

# Image ref of one compose.yml service. (`config --images <svc>` also lists
# the service's dependencies, hence the json route.)
_image service:
    @docker compose -f compose.yml config --format json | docker run --rm -i {{jq}} -er '.services["{{service}}"].image // error("no service {{service}} in compose.yml")'

# Run each config through the binary that will load it.
validate:
    docker run --rm --network none -v ./config/prometheus.yaml:/etc/prometheus/prometheus.yaml:ro --entrypoint promtool $(just _image prometheus) check config /etc/prometheus/prometheus.yaml
    docker run --rm --network none -e OTLP_AUTH_TOKEN=dummy -e DEPARTMENT=dummy -v ./config/otel-collector.yaml:/etc/otelcol/config.yaml:ro $(just _image otel-collector) validate --config=/etc/otelcol/config.yaml
    docker run --rm --network none -v ./config/loki.yaml:/etc/loki/loki.yaml:ro $(just _image loki) -config.file=/etc/loki/loki.yaml -verify-config
    docker run --rm --network none -v ./config/tempo.yaml:/etc/tempo/tempo.yaml:ro $(just _image tempo) -config.file=/etc/tempo/tempo.yaml -config.verify=true

# Runs against a copy of the sources: state and tfvars never enter the
# container, which has network access to fetch the provider.
# Full OpenTofu validation (downloads the provider, so not part of `check`).
infra-validate:
    @d=$(mktemp -d) && cp infra/main.tf infra/.terraform.lock.hcl "$d"/ && docker run --rm --entrypoint sh -v "$d":/src:ro {{tofu}} -c 'mkdir /work && cp /src/main.tf /src/.terraform.lock.hcl /work && cd /work && tofu init -backend=false -input=false >/dev/null && tofu validate'; rc=$?; rm -rf "$d"; exit $rc

# Format YAML in place (--user so the rewritten files stay yours).
fmt:
    docker run --rm --network none --user "$(id -u):$(id -g)" -v .:/code -w /code {{yamlfmt}} .

# Install the git hooks: gitleaks on commit, `just check` on push (see .pre-commit-config.yaml).
hooks:
    prek install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push

# Snapshot all stateful volumes to backups/<timestamp>.tar.gz (mode 0600: it holds secrets).
backup: (_backup core_project "backups")

# gzip -1: the stack is paused for as long as the tar runs, and the chunks are
# already compressed. The unpause runs unconditionally (`pause` can fail
# halfway), and a failed unpause fails the recipe.
_backup project dir:
    mkdir -p {{dir}}
    @-docker compose -p {{project}} unpause {{stateful}} >/dev/null 2>&1
    @rc=0; m=$(for s in {{stateful}}; do printf -- '-v {{project}}_%s_data:/data/%s ' $s $s; done); docker compose -p {{project}} pause {{stateful}} && docker run --rm --network none $m -v {{absolute_path(dir)}}:/backups {{alpine}} sh -c 'set -o pipefail; umask 077 && tar cf - -C /data . | gzip -1 > /backups/monitoring-$(date +%Y%m%d-%H%M%S).tar.gz' || rc=$?; docker compose -p {{project}} unpause {{stateful}} || { echo "error: unpause failed; the stack is still paused" >&2; rc=1; }; exit $rc
    @ls -lh {{dir}}/ | tail -1

# Restore a backup tarball into the volumes (stops the stack; wipes current state).
restore file: (_restore core_project file "backups")
    @echo "Restored {{file}}. Run 'just up' to start the stack."

# The current state is snapshotted to <dir>/pre-restore-*.tar.gz first: if the
# extract dies halfway, that is the only way back.
_restore project file dir:
    @[ -f "{{file}}" ] || { echo "error: {{file}} not found" >&2; exit 1; }
    docker run --rm --network none -v {{absolute_path(file)}}:/backup.tar.gz:ro {{alpine}} tar tzf /backup.tar.gz > /dev/null
    docker compose -p {{project}} down --remove-orphans
    mkdir -p {{dir}}
    m=$(for s in {{stateful}}; do printf -- '-v {{project}}_%s_data:/data/%s ' $s $s; done); docker run --rm --network none $m -v {{absolute_path(dir)}}:/backups {{alpine}} sh -c 'umask 077 && tar czf /backups/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz -C /data .'
    m=$(for s in {{stateful}}; do printf -- '-v {{project}}_%s_data:/data/%s ' $s $s; done); docker run --rm --network none $m -v {{absolute_path(file)}}:/backup.tar.gz:ro {{alpine}} sh -c 'for d in /data/*; do find "$d" -mindepth 1 -delete; done && tar xzf /backup.tar.gz -C /data'

# Needs a booted smoke stack (`just smoke`). Run it after touching _backup/_restore.
# COMPOSE_FILE is pinned so the host's overlay list stays out, as for `smoke`.
# Round-trip backup and restore on the smoke stack.
restore-check:
    @export COMPOSE_FILE=compose.yml:compose.sandbox.yml; d=$(mktemp -d) && just _backup {{smoke_project}} "$d" && f=$(ls "$d"/monitoring-*.tar.gz) && just _restore {{smoke_project}} "$f" "$d" && docker run --rm --network none -v {{smoke_project}}_grafana_data:/g:ro {{alpine}} test -s /g/grafana.db && echo "Backup round-trip ok"; rc=$?; rm -rf "$d"; exit $rc

# `--wait` blocks on the healthchecks and fails if any container exits, so a
# crash-looping service is caught (after the full timeout). scripts/smoke.sh
# asserts what lands after that: provisioning, scrapes, the data paths.
# Boot an isolated copy of the core stack and assert it works end to end.
smoke: (_queue-volume smoke_project)
    {{compose_smoke}} up -d --wait --wait-timeout 120
    {{smoke_env}} SMOKE_URL=http://localhost:{{smoke_port}} SMOKE_PROJECT={{smoke_project}} scripts/smoke.sh

# Logs from the smoke stack (its own project, so `just logs` will not show it).
smoke-logs:
    {{compose_smoke}} logs --no-color --tail=200

# Tear down the smoke stack and its throwaway volumes.
smoke-down:
    {{compose_smoke}} down --remove-orphans --volumes -t 1
