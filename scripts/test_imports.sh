#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/monitoring-imports.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/infra"
cp "$root/infra/generate-imports.sh" "$scratch/infra/"
cat >"$scratch/infra/terraform.tfvars" <<'EOF'
account_id = "fixture-account"
zone_id = "fixture-zone"
domain = "fixture.example"
EOF
cat >"$scratch/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
    *cfd_tunnel*) echo '{"result":[{"name":"cml-monitoring","id":"tunnel"}]}' ;;
    *name=ntfy.*)
        [[ "$NTFY_FIXTURE" != failure ]] || exit 22
        if [[ "$NTFY_FIXTURE" == absent ]]; then echo '{"result":[]}'
        else echo '{"result":[{"id":"ntfy-record"}]}'
        fi ;;
    *dns_records*) echo '{"result":[{"id":"dns-record"}]}' ;;
    *) echo '{"result":[]}' ;;
esac
EOF
chmod +x "$scratch/bin/curl"
for fixture in present absent failure; do
    rc=0
    env -i PATH="$scratch/bin:$PATH" CLOUDFLARE_API_TOKEN=fixture NTFY_FIXTURE="$fixture" \
        bash "$scratch/infra/generate-imports.sh" >"$scratch/out" 2>"$scratch/err" || rc=$?
    case "$fixture" in
        present) [[ "$rc" == 0 ]] && grep 'cloudflare_dns_record.ntfy' "$scratch/out" >/dev/null ;;
        absent) [[ "$rc" == 0 ]] && ! grep 'cloudflare_dns_record.ntfy' "$scratch/out" >/dev/null ;;
        failure) [[ "$rc" != 0 ]] && grep 'DNS lookup for ntfy.fixture.example failed' "$scratch/err" >/dev/null ;;
    esac || {
        cat "$scratch/err" >&2
        echo "error: ntfy DNS $fixture check failed" >&2
        exit 1
    }
done
echo 'Import lookup checks passed'
