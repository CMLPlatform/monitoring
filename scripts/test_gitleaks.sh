#!/bin/sh
set -eu

# Git hooks export index and worktree paths; scratch repositories must not inherit them.
for name in $(git rev-parse --local-env-vars); do unset "$name"; done
root=$(pwd)
d=$(mktemp -d "${TMPDIR:-/tmp}/monitoring-gitleaks.XXXXXX")
trap 'rm -rf "$d"' EXIT HUP INT TERM

git -c core.hooksPath=/dev/null init -q "$d/main"
cd "$d/main"
cat >.gitleaks.toml <<'EOF'
[[rules]]
id = "regression-fixture"
description = "Synthetic regression credential"
regex = '''fixture-secret-[0-9]{8}'''
EOF
git add .gitleaks.toml
git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.org commit -qm initial
git -c core.hooksPath=/dev/null worktree add -q "$d/linked"
cp "$root/justfile" "$d/linked/justfile"
cd "$d/linked"
mkdir dashboards
printf '{}\n' >dashboards/fixture.json

expect_leak() {
	rc=0
	just "$@" >"$d/output" 2>&1 || rc=$?
	# just preserves the failing recipe status in its diagnostic, but exits 1 itself.
	if [ "$rc" -ne 1 ] || ! grep -q 'leaks found: 1' "$d/output"; then
		cat "$d/output" >&2
		echo "error: $* did not detect the synthetic credential" >&2
		exit 1
	fi
}

just _gitleaks
printf 'fixture-secret-%s\n' 12345678 >credential.txt
git add credential.txt
expect_leak _gitleaks-staged
git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.org commit -qm fixture
expect_leak _gitleaks
printf 'gitdir: /missing-git-dir\n' >.git
if just _gitleaks >"$d/output" 2>&1; then
	echo "error: a broken Git directory passed the scan" >&2
	exit 1
fi
echo "gitleaks detects staged and committed credentials in linked worktrees and rejects broken Git directories"
