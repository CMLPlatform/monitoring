#!/bin/sh
# Exercise the real recipe without pausing a Docker stack.
set -eu
cd "$(dirname "$0")/.."
d=$(mktemp -d "${TMPDIR:-/tmp}/monitoring-backup-test.XXXXXX")
trap 'rm -rf "$d"' EXIT
cat >"$d/docker" <<'DOCKER'
#!/bin/sh
case "$*" in
  *'config --format json'*) echo '{}' ;;
  *' -er '*) echo archive-image ;;
  *' pause '*) echo pause >>"$TEST_EVENTS"; [ "$TEST_CASE" != pause-failure ] || exit 6 ;;
  *' unpause '*)
    echo unpause >>"$TEST_EVENTS"
    if { [ "$TEST_CASE" = unpause-failure ] || [ "$TEST_CASE" = both-fail ]; } && grep -qx pause "$TEST_EVENTS"; then exit 9; fi ;;
  *'run --rm --network none'*)
    touch "$(dirname "$TEST_EVENTS")/monitoring-test.tar.gz"
    case "$TEST_CASE" in
      TERM) kill -TERM "$PPID" ;;
      INT) kill -INT "$PPID" ;;
      archive-failure|both-fail) exit 7 ;;
    esac ;;
  *) echo "unexpected docker call" >&2; exit 1 ;;
esac
DOCKER
chmod +x "$d/docker"
for scenario in success TERM INT pause-failure archive-failure unpause-failure both-fail; do
	: >"$d/events"
	case "$scenario" in success) expected=0 ;; TERM) expected=143 ;; INT) expected=130 ;; pause-failure) expected=6 ;; archive-failure | both-fail) expected=7 ;; *) expected=1 ;; esac
	rc=0
	env -i PATH="$d:$PATH" HOME="$HOME" TEST_EVENTS="$d/events" TEST_CASE="$scenario" just _backup test-backup "$d" >"$d/output" 2>&1 || rc=$?
	# just normalizes signal exits to 128+signal, and propagates recipe failures.
	[ "$rc" -eq "$expected" ] || {
		cat "$d/output" >&2
		echo "wrong exit for $scenario: $rc" >&2
		exit 1
	}
	[ "$(tail -1 "$d/events")" = unpause ] || {
		echo "backup left services paused after $scenario" >&2
		exit 1
	}
	echo "backup $scenario: cleanup attempted, exit $rc"
done
