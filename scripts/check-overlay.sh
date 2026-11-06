#!/usr/bin/env bash
# Render the CML overlay (copier.yml, templates/spoke/) with and without the GPU answer
# and check what a project receives: exactly the expected files, each vendored file
# byte-identical to its source, and the answers rendered into the .env example.
#
#   scripts/check-overlay.sh [copier command...]   (default: copier)
#
# Renders a copy of the template outside git, so it checks the working tree, not a commit.
set -euo pipefail

copier=("${@:-copier}")
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src/templates"
cp "$root/copier.yml" "$work/src/"
cp -R "$root/templates/spoke" "$work/src/templates/"

fail() { echo "error: $*" >&2; exit 1; }
vendored=(compose.telemetry.yml deploy/alloy/config.alloy scripts/run_scheduled.sh)

for gpu in true false; do
    out="$work/out-$gpu"
    "${copier[@]}" copy --quiet --defaults --data project=demo-app --data env=staging \
        --data gpu="$gpu" "$work/src" "$out"
    expected=("${vendored[@]}")
    [[ "$gpu" == false ]] || expected+=(compose.telemetry.gpu.yml)
    got="$(cd "$out" && find . -type f | sed 's|^\./||' | sort)"
    want="$(printf '%s\n' "${expected[@]}" telemetry.env.example .copier-answers.cml.yml | sort)"
    [[ "$got" == "$want" ]] || fail "gpu=$gpu rendered:"$'\n'"$got"$'\n'"expected:"$'\n'"$want"
    for f in "${expected[@]}"; do
        cmp -s "$root/templates/spoke/$f" "$out/$f" || fail "gpu=$gpu: $f differs from templates/spoke/$f"
    done
    [[ -x "$out/scripts/run_scheduled.sh" ]] || fail "run_scheduled.sh lost its executable bit"
    gpu_metrics=""
    [[ "$gpu" == false ]] || gpu_metrics=1
    for line in PROJECT=demo-app ENVIRONMENT=staging "GPU_METRICS=$gpu_metrics" OTLP_AUTH_TOKEN=; do
        grep -qx "$line" "$out/telemetry.env.example" || fail "gpu=$gpu: telemetry.env.example lacks '$line'"
    done
    grep -qx "_src_path: $work/src" "$out/.copier-answers.cml.yml" || fail "gpu=$gpu: the answers file does not record its template"
done

# bootstrap.sh refuses these names; the overlay must too.
for bad in Demo -demo "demo app"; do
    ! "${copier[@]}" copy --quiet --defaults --data project="$bad" "$work/src" "$work/bad" >/dev/null 2>&1 \
        || fail "the overlay accepted project='$bad'"
done
echo "overlay ok: both renders match templates/spoke/"
