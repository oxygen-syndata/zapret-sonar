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
mkdir -p "$ZF_ZAPRET_BASE/nfq" "$ZF_ZAPRET_BASE/ip2net" "$ZF_ZAPRET_BASE/mdig" "$ZF_RUNTIME_DIR"
for name in nfqws ip2net mdig; do
    case "$name" in
        nfqws) dest="$ZF_ZAPRET_BASE/nfq/$name" ;;
        *) dest="$ZF_ZAPRET_BASE/$name/$name" ;;
    esac
    printf '#!/usr/bin/env bash\nprintf "old %s\\n"\n' "$name" > "$dest"
    chmod +x "$dest"
done

root="$TEST_DIR/zapret-v99/binaries/linux-x86_64"
mkdir -p "$root"
for name in nfqws ip2net mdig; do
    printf '#!/usr/bin/env bash\nprintf "new %s\\n"\n' "$name" > "$root/$name"
    chmod +x "$root/$name"
done
tar -czf "$TEST_DIR/zapret.tar.gz" -C "$TEST_DIR" zapret-v99
( cd "$TEST_DIR" && sha256sum zapret-v99/binaries/linux-x86_64/{nfqws,ip2net,mdig} ) > "$TEST_DIR/sha256sum.txt"

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
_zf_require_root() { :; }
_zf_lock() { :; }
_zf_detect_arch() { printf 'linux-x86_64\n'; }
_zf_invalidate_update_caches() { :; }
curl() {
    local out="" src
    while (( $# )); do
        if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi
    done
    [[ "$out" == *sha256sum.txt ]] && src="$TEST_DIR/sha256sum.txt" || src="$TEST_DIR/zapret.tar.gz"
    cp "$src" "$out"
}
systemctl() {
    case "$1" in
        is-active) printf 'inactive\n'; return 3 ;;
        stop|start) printf '%s\n' "$1" >> "$TEST_DIR/systemctl.log" ;;
    esac
}

cmd_do_upgrade v99 >/dev/null
[[ "$($ZF_NFQWS)" == 'new nfqws' ]]
[[ ! -e "$TEST_DIR/systemctl.log" ]]
printf 'PASS: engine upgrade preserves an inactive service\n'
