#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export ZF_LIBRARY_MODE=1
export ZF_ZAPRET_BASE="$TEST_DIR/zapret"
export ZF_RUNTIME_DIR="$TEST_DIR/run"
export ZF_UPDATE_CACHE_DIR="$TEST_DIR/cache"
mkdir -p "$ZF_ZAPRET_BASE/.flowseal-releases/old/strategies" \
    "$ZF_ZAPRET_BASE/.flowseal-releases/old/bin" \
    "$ZF_ZAPRET_BASE/.flowseal-releases/old/lists" \
    "$ZF_ZAPRET_BASE/nfq"
ln -s '.flowseal-releases/old' "$ZF_ZAPRET_BASE/flowseal-current"
printf 'old\n' > "$ZF_ZAPRET_BASE/.flowseal-version"
printf '# zapret-sonar-strategy: general.bat\n# zapret-sonar-gamefilter: off\n# zapret-sonar-ipset: none\n' > "$ZF_ZAPRET_BASE/config"
printf '@echo off\n"%%BIN%%winws.exe" --wf-tcp=443 --dpi-desync=fake\n' \
    > "$ZF_ZAPRET_BASE/.flowseal-releases/old/strategies/general.bat"
: > "$ZF_ZAPRET_BASE/.flowseal-releases/old/bin/fake.bin"
printf '203.0.113.113/32\n' > "$ZF_ZAPRET_BASE/.flowseal-releases/old/lists/ipset-all.txt"
printf '#!/usr/bin/env bash\nprintf "github version v72.13 (test)\\n"\n' > "$ZF_ZAPRET_BASE/nfq/nfqws"
chmod +x "$ZF_ZAPRET_BASE/nfq/nfqws"

mkdir -p "$TEST_DIR/source/bin" "$TEST_DIR/source/lists"
printf '@echo off\n"%%BIN%%winws.exe" --wf-tcp=443 --dpi-desync=fake\n' > "$TEST_DIR/source/general.bat"
: > "$TEST_DIR/source/bin/fake.bin"
printf '203.0.113.113/32\n' > "$TEST_DIR/source/lists/ipset-all.txt"
tar -czf "$TEST_DIR/flowseal.tar.gz" -C "$TEST_DIR" source

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
need_root() { return 0; }
_zf_lock() { :; }
_zf_github_latest_tag() { printf 'new\n'; }
curl() {
    local out=""
    while (( $# )); do
        if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else shift; fi
    done
    cp "$TEST_DIR/flowseal.tar.gz" "$out"
}
cmd_apply() {
    [[ "$(readlink "$ZF_ZAPRET_BASE/flowseal-current")" == '.flowseal-releases/old' ]]
}

for attempt in 1 2; do
    printf 'Testing failed update attempt %d...\n' "$attempt"
    if ( cmd_update --force ) >/dev/null 2>&1; then
        printf 'FAIL: failed update reported success\n' >&2
        exit 1
    fi
    [[ "$(readlink "$ZF_ZAPRET_BASE/flowseal-current")" == '.flowseal-releases/old' ]]
    [[ "$(cat "$ZF_ZAPRET_BASE/.flowseal-version")" == old ]]
    [[ "$(find "$ZF_ZAPRET_BASE/.flowseal-releases" -mindepth 1 -maxdepth 1 -type d | wc -l)" == 1 ]]
done

printf 'PASS: repeated failed updates preserve the old release and version\n'

zf_restore_flowseal_tree() { return 1; }
if output=$(cmd_update --force 2>&1); then
    printf 'FAIL: update with failed rollback reported success\n' >&2
    exit 1
fi
[[ "$output" == *'автоматический откат набора Flowseal не удался'* ]]
[[ "$(cat "$ZF_ZAPRET_BASE/.flowseal-version")" == old ]]
printf 'PASS: failed Flowseal rollback is reported explicitly\n'
