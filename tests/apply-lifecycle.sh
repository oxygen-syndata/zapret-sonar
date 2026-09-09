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
mkdir -p "$ZF_ZAPRET_BASE/nfq" "$ZF_RUNTIME_DIR"
printf '#!/usr/bin/env bash\nprintf "github version v72.13 (test)\\n"\n' > "$ZF_ZAPRET_BASE/nfq/nfqws"
chmod +x "$ZF_ZAPRET_BASE/nfq/nfqws"

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
_zf_require_root() { :; }
_zf_lock() { :; }

printf 'old-config\n' > "$ZF_ZAPRET_CONFIG"
service_state=active
restart_count=0
systemctl() {
    case "$1" in
        is-active) printf '%s\n' "$service_state"; [[ "$service_state" == active ]] ;;
        restart)
            restart_count=$((restart_count + 1))
            if (( restart_count == 1 )); then service_state=failed; return 1; fi
            service_state=active ;;
        stop) service_state=inactive ;;
        start) service_state=active ;;
    esac
}
cmd_render() { printf 'new-config\n' > "$ZF_ZAPRET_CONFIG"; }

if cmd_apply general.bat off none >/dev/null 2>&1; then
    printf 'FAIL: apply reported success after failed restart\n' >&2
    exit 1
fi
[[ "$(cat "$ZF_ZAPRET_CONFIG")" == old-config ]]
[[ "$service_state" == active ]]
printf 'PASS: failed apply restores config and active service\n'

printf 'old-config\n' > "$ZF_ZAPRET_CONFIG"
service_state=active
restart_count=0
cmd_render() { return 1; }
if cmd_apply general.bat off none >/dev/null 2>&1; then
    printf 'FAIL: apply with failed render reported success\n' >&2
    exit 1
fi
[[ "$(cat "$ZF_ZAPRET_CONFIG")" == old-config ]]
[[ "$service_state" == active ]]
(( restart_count == 0 ))
printf 'PASS: failed render does not restart an unchanged service\n'

run_failed_try() {
    local initial="$1" state_file log
    state_file="$TEST_DIR/state-$initial"
    log="$TEST_DIR/log-$initial"
    printf '%s\n' "$initial" > "$state_file"
    printf '# zapret-sonar-strategy: general.bat\n# zapret-sonar-gamefilter: off\n# zapret-sonar-ipset: none\nold=true\n' > "$ZF_ZAPRET_CONFIG"
    systemctl() {
        local state; state=$(cat "$state_file")
        case "$1" in
            is-active) printf '%s\n' "$state"; [[ "$state" == active ]] ;;
            stop) printf 'stop\n' >> "$log"; printf 'inactive\n' > "$state_file" ;;
            start|restart) printf '%s\n' "$1" >> "$log"; printf 'active\n' > "$state_file" ;;
        esac
    }
    _zf_lock() { :; }
    zf_baseline() { return 1; }
    if ( cmd_try ) >/dev/null 2>&1; then
        printf 'FAIL: try without blocked targets reported success\n' >&2
        return 1
    fi
    [[ "$(cat "$state_file")" == "$initial" ]]
    grep -q '^old=true$' "$ZF_ZAPRET_CONFIG"
}

run_failed_try active
run_failed_try inactive
printf 'PASS: failed try restores active and inactive service states\n'
