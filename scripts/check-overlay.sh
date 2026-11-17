#!/usr/bin/env bash
# Render both layers of the CML overlay (copier.yml, templates/spoke/<layer>/), the host
# one with and without the GPU answer, and check what a repo receives: exactly the
# expected files, each vendored file byte-identical to its source, and the answers
# rendered where they belong. Bad answers must be refused.
#
#   scripts/check-overlay.sh [copier command...]   (default: copier)
#
# With OVERLAY_OUT set, the renders stay in that directory (`just overlay-check`
# validates the host one with Alloy). Renders a copy of the template outside git, so it
# checks the working tree, not a commit. Also exercises tagged copy/update with
# both layers in one application repo, preserving its base-template answers.
set -euo pipefail

copier=("${@:-copier}")
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Scratch repositories must not inherit a caller's index or Git directory.
while IFS= read -r git_var; do
    unset "$git_var"
done < <(git rev-parse --local-env-vars)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out_root="${OVERLAY_OUT:-$work}"
mkdir -p "$work/src/templates"
cp "$root/copier.yml" "$work/src/"
cp -R "$root/templates/spoke" "$work/src/templates/"

fail() {
    echo "error: $*" >&2
    exit 1
}
host_answers=(--data layer=host --answers-file .copier-answers.cml-host.yml)

# Exactly these files, and the vendored ones ($3...) byte-identical to their source.
check_files() {
    local out="$1" layer="$2" got want f
    shift 2
    got="$(cd "$out" && find . -type f | sed 's|^\./||' | sort)"
    want="$(printf '%s\n' "${expected[@]}" | sort)"
    [[ "$got" == "$want" ]] || fail "$out rendered:"$'\n'"$got"$'\n'"expected:"$'\n'"$want"
    for f in "$@"; do
        cmp -s "$root/templates/spoke/$layer/$f" "$out/$f" || fail "$out: $f differs from templates/spoke/$layer/$f"
    done
}

has_lines() {
    local file="$1" line
    shift
    for line in "$@"; do
        grep -qxF -- "$line" "$file" || fail "$file lacks '$line'"
    done
}

# --------------------------------------------------------------------- project layer
out="$out_root/project"
"${copier[@]}" copy --quiet --defaults --data project=demo-app --data env=staging \
    --data contact=ops@example.org "$work/src" "$out"
expected=(scripts/run_scheduled.sh telemetry.env.example .copier-answers.cml.yml)
check_files "$out" project scripts/run_scheduled.sh
[[ -x "$out/scripts/run_scheduled.sh" ]] || fail "run_scheduled.sh lost its executable bit"
has_lines "$out/telemetry.env.example" PROJECT=demo-app ENVIRONMENT=staging OTLP_AUTH_TOKEN= \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    "OTEL_EXPORTER_OTLP_HEADERS=\"Authorization=Bearer \${OTLP_AUTH_TOKEN}\"" \
    "OTEL_RESOURCE_ATTRIBUTES=project=demo-app,env=staging" \
    "# Questions about this project's telemetry: ops@example.org"
has_lines "$out/.copier-answers.cml.yml" "_src_path: $work/src" "layer: project"

# ------------------------------------------------------------------------ host layer
for gpu in true false; do
    out="$out_root/host-$gpu"
    "${copier[@]}" copy --quiet --defaults "${host_answers[@]}" --data project=demo-app \
        --data gpu="$gpu" --data "stacks=demo-app=demo-app/prod other_stack=other/staging" \
        "$work/src" "$out"
    vendored=(compose.telemetry.yml deploy/alloy/config.alloy)
    [[ "$gpu" == false ]] || vendored+=(compose.telemetry.gpu.yml)
    expected=("${vendored[@]}" deploy/alloy/projects.alloy telemetry-host.env.example .copier-answers.cml-host.yml)
    check_files "$out" host "${vendored[@]}"
    gpu_metrics=""
    [[ "$gpu" == false ]] || gpu_metrics=1
    has_lines "$out/telemetry-host.env.example" PROJECT=demo-app ENVIRONMENT=prod OTLP_AUTH_TOKEN= \
        "GPU_METRICS=$gpu_metrics"
    has_lines "$out/.copier-answers.cml-host.yml" "layer: host"
    # Each stack maps in both relabel components: two rules match its Compose project.
    for want in 'regex         = "other_stack"/4' 'replacement   = "other"/2' 'replacement   = "staging"/2'; do
        [[ "$(grep -cF "${want%/*}" "$out/deploy/alloy/projects.alloy")" == "${want##*/}" ]] ||
            fail "projects.alloy does not have ${want##*/} of: ${want%/*}"
    done
done

# ---------------------------------------------------------------------- bad answers
refuse() {
    local what="$1"
    shift
    ! "${copier[@]}" copy --quiet --defaults "$@" "$work/src" "$work/bad" >/dev/null 2>&1 ||
        fail "the overlay accepted $what"
    rm -rf "$work/bad"
}
# bootstrap.sh refuses these names; the overlay must too.
for bad in Demo -demo "demo app"; do
    refuse "project='$bad'" --data project="$bad"
    refuse "env='$bad'" --data project=demo --data env="$bad"
done
refuse "stacks='Bad=x/y'" "${host_answers[@]}" --data project=demo --data stacks=Bad=x/y
refuse "duplicate Compose projects" "${host_answers[@]}" --data project=demo --data "stacks=app=one/prod app=two/prod"
refuse "stacks='demo=demo'" "${host_answers[@]}" --data project=demo --data stacks=demo=demo
# One answers file per layer, or the two overwrite each other's answers.
refuse "the host layer in .copier-answers.cml.yml" --data layer=host --data project=demo
refuse "the project layer in .copier-answers.cml-host.yml" --answers-file .copier-answers.cml-host.yml --data project=demo
# A tagged update must preserve the base template and the other layer's state.
fixture_git() {
    local dir="$1"
    shift
    git -C "$dir" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name='Template test' \
        -c user.email=template@example.org "$@"
}
fixture_git "$work/src" init --quiet --initial-branch=main
while IFS= read -r -d '' file; do
    fixture_git "$work/src" add -- "${file#"$work/src/"}"
done < <(find "$work/src" -path "$work/src/.git" -prune -o -type f -print0)
fixture_git "$work/src" commit --quiet -m 'test: initial template'
fixture_git "$work/src" tag v0.0.1

out="$work/update"
mkdir -p "$out"
printf 'project_name: demo-app\n' >"$out/.copier-answers.yml"
printf 'Application-owned content\n' >"$out/README.md"
cp "$out/.copier-answers.yml" "$work/base-answers"
fixture_git "$out" init --quiet --initial-branch=main
"${copier[@]}" copy --quiet --defaults --vcs-ref=v0.0.1 --data project=demo-app \
    --data env=staging "$work/src" "$out"
"${copier[@]}" copy --quiet --defaults --vcs-ref=v0.0.1 "${host_answers[@]}" \
    --data project=demo-app --data gpu=true "$work/src" "$out"
fixture_git "$out" add -- .copier-answers.yml README.md .copier-answers.cml.yml \
    .copier-answers.cml-host.yml scripts/run_scheduled.sh telemetry.env.example \
    telemetry-host.env.example compose.telemetry.yml compose.telemetry.gpu.yml \
    deploy/alloy/config.alloy deploy/alloy/projects.alloy
fixture_git "$out" commit --quiet -m 'test: apply both layers'

printf '\n# Updated project template\n' >>"$work/src/templates/spoke/project/telemetry.env.example.jinja"
printf '\n// Updated host template\n' >>"$work/src/templates/spoke/host/deploy/alloy/config.alloy"
fixture_git "$work/src" add -- templates/spoke/project/telemetry.env.example.jinja \
    templates/spoke/host/deploy/alloy/config.alloy
fixture_git "$work/src" commit --quiet -m 'test: update both templates'
fixture_git "$work/src" tag v0.0.2

cp "$out/.copier-answers.cml-host.yml" "$work/host-answers"
"${copier[@]}" update --quiet --defaults --vcs-ref=v0.0.2 \
    --answers-file .copier-answers.cml.yml "$out"
cmp -s "$work/host-answers" "$out/.copier-answers.cml-host.yml" || fail 'project update changed host answers'
has_lines "$out/telemetry.env.example" '# Updated project template' ENVIRONMENT=staging
fixture_git "$out" add -- .copier-answers.cml.yml telemetry.env.example
fixture_git "$out" commit --quiet -m 'test: update project layer'
"${copier[@]}" update --quiet --defaults --vcs-ref=v0.0.2 \
    --answers-file .copier-answers.cml-host.yml --data gpu=false \
    --data 'stacks=demo-app=demo-app/prod other_stack=other/staging' "$out"
has_lines "$out/deploy/alloy/config.alloy" '// Updated host template'
has_lines "$out/telemetry-host.env.example" GPU_METRICS=
[[ ! -e "$out/compose.telemetry.gpu.yml" ]] || fail 'GPU opt-out left its Compose file behind'
[[ ! -e "$out/telemetry.env.example.rej" ]] || fail 'project update conflicted'
cmp -s "$work/base-answers" "$out/.copier-answers.yml" || fail 'overlay update changed base answers'
has_lines "$out/README.md" 'Application-owned content'
fixture_git "$out" add -- .copier-answers.cml-host.yml \
    telemetry-host.env.example compose.telemetry.gpu.yml \
    deploy/alloy/config.alloy deploy/alloy/projects.alloy
fixture_git "$out" commit --quiet -m 'test: update both layers'
for answers in .copier-answers.cml.yml .copier-answers.cml-host.yml; do
    "${copier[@]}" update --quiet --defaults --vcs-ref=v0.0.2 --answers-file "$answers" "$out"
done
[[ -z "$(fixture_git "$out" status --porcelain)" ]] || fail 'repeated update changed the application'
echo 'overlay ok: tagged updates preserve both layers and base answers'

echo "overlay ok: both layers match templates/spoke/"
