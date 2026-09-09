#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export ZF_LIBRARY_MODE=1
export ZF_ZAPRET_BASE="$TEST_DIR/zapret"
export ZF_ZAPRET_CONFIG="$ZF_ZAPRET_BASE/config"
export ZF_RUNTIME_DIR="$TEST_DIR/run"
export ZF_UPDATE_CACHE_DIR="$TEST_DIR/cache"
releases="$ZF_ZAPRET_BASE/.flowseal-releases"
for id in old current; do
    mkdir -p "$releases/$id/strategies" "$releases/$id/bin" "$releases/$id/lists"
    printf '@echo off\n"%%BIN%%winws.exe" --wf-tcp=443 --dpi-desync=fake\n' > "$releases/$id/strategies/general.bat"
    : > "$releases/$id/bin/fake.bin"
    printf '203.0.113.113/32\n' > "$releases/$id/lists/ipset-all.txt"
    printf 'upstream.example\n' > "$releases/$id/lists/list-general.txt"
done
printf 'private.example\n' > "$releases/current/lists/list-general-user.txt"
ln -s .flowseal-releases/current "$ZF_ZAPRET_BASE/flowseal-current"
printf '2.0.0\n' > "$ZF_ZAPRET_BASE/.flowseal-version"
printf '# zapret-sonar-strategy: general.bat\n# zapret-sonar-gamefilter: off\n# zapret-sonar-ipset: none\n' > "$ZF_ZAPRET_CONFIG"
mkdir -p "$ZF_ZAPRET_BASE/nfq" "$ZF_RUNTIME_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ZF_ZAPRET_BASE/nfq/nfqws"; chmod +x "$ZF_ZAPRET_BASE/nfq/nfqws"

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
zf_write_flowseal_metadata "$releases/current" "$releases" 2.0.0 2026-09-09T00:00:00Z
zf_write_flowseal_metadata "$releases/old" "$releases" 1.0.0 2026-09-08T00:00:00Z
need_root() { return 0; }
_zf_lock() { :; }
_zf_require_root() { :; }
_zf_invalidate_update_caches() { :; }
zf_validate_flowseal_tree() { return 0; }
cmd_apply() { [[ "$(readlink "$ZF_FLOWSEAL_CURRENT")" == .flowseal-releases/old ]]; }

json=$(cmd_snapshots --json)
jq -e '.schema_version == 1 and .command == "snapshots" and (.snapshots | length) == 2' <<< "$json" >/dev/null
cmd_rollback old >/dev/null
[[ "$(readlink "$ZF_FLOWSEAL_CURRENT")" == .flowseal-releases/old ]]
[[ "$(cat "$ZF_ZAPRET_BASE/.flowseal-version")" == 1.0.0 ]]
[[ "$(cat "$releases/old/lists/list-general-user.txt")" == private.example ]]
printf 'PASS: public Flowseal rollback validates and switches snapshots\n'

ln -sfn .flowseal-releases/current "$ZF_ZAPRET_BASE/flowseal-current"
printf '2.0.0\n' > "$ZF_ZAPRET_BASE/.flowseal-version"
service_state=inactive
systemctl() {
    case "$1" in
        is-active) printf '%s\n' "$service_state"; return 3 ;;
        stop) service_state=inactive ;;
        restart|start) service_state=active ;;
    esac
}
cmd_apply() { return 99; }
render_count=0
cmd_render() {
    render_count=$((render_count + 1))
    if (( render_count == 1 )); then
        [[ "$(readlink "$ZF_FLOWSEAL_CURRENT")" == .flowseal-releases/old ]]
    else
        [[ "$(readlink "$ZF_FLOWSEAL_CURRENT")" == .flowseal-releases/current ]]
    fi
}
zf_set_ipset_mode() { return 0; }
cmd_rollback old >/dev/null
[[ "$service_state" == inactive ]]
printf 'PASS: Flowseal rollback preserves an inactive service\n'
