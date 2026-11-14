#!/usr/bin/env bash
# The caller supplies a booted disposable project; never use production volumes.
set -euo pipefail
cd "$(dirname "$0")/.."
export COMPOSE_FILE=compose.yml:compose.sandbox.yml
project=$1
shift
img=$(just _image compose.yml otel-queue-init)
d=$(mktemp -d "${TMPDIR:-/tmp}/monitoring-restore-check.XXXXXX")
marker=${d##*/}
mounts=()
for service in "$@"; do
	mounts+=(-v "${project}_${service}_data:/data/$service")
done
cleanup() {
	rc=$?
	trap - EXIT
	docker run --rm --network none "${mounts[@]}" "$img" sh -c 'for volume in /data/*; do rm -f "$volume/$1" "$volume/$1-later"; done' _ "$marker" || { [ "$rc" -ne 0 ] || rc=1; }
	rm -rf "$d"
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Different contents in each volume catch missing or crossed mounts.
docker run --rm --network none "${mounts[@]}" "$img" sh -ec 'for volume in /data/*; do printf "%s-before\n" "${volume##*/}" >"$volume/$1"; done' _ "$marker"
just _backup "$project" "$d"
f=$(find "$d" -name 'monitoring-*.tar.gz')
docker run --rm --network none "${mounts[@]}" "$img" sh -ec 'for volume in /data/*; do printf "%s-after\n" "${volume##*/}" >"$volume/$1"; touch "$volume/$1-later"; done' _ "$marker"
just _restore "$project" "$f" "$d"
docker run --rm --network none "${mounts[@]}" "$img" sh -ec '
for volume in /data/*; do
	[ "$(cat "$volume/$1")" = "${volume##*/}-before" ] && [ ! -e "$volume/$1-later" ] || { echo "error: ${volume##*/} was not restored" >&2; exit 1; }
done' _ "$marker"
docker compose -p "$project" up -d --wait --wait-timeout 120
docker compose -p "$project" exec -T grafana wget -qO- http://localhost:3000/api/health | grep -Eq '"database":[[:space:]]*"ok"'
echo 'Backup round-trip ok: all five volumes restored; Grafana database healthy'
