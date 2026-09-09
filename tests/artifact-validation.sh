#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export ZF_INSTALL_LIBRARY_MODE=1
export ZAPRET_BASE="$TEST_DIR/install"
export BIN_DEST="$TEST_DIR/bin"
export SERVICE_NAME=zapret-test
export ZF_RUNTIME_DIR="$TEST_DIR/run"
mkdir -p "$BIN_DEST" "$ZF_RUNTIME_DIR"

# shellcheck source=../install.sh
source "$PROJECT_DIR/install.sh"

make_zapret_archive() {
    local root="$TEST_DIR/source/zapret-v99/binaries/linux-x86_64" name
    rm -rf "$TEST_DIR/source"
    mkdir -p "$root"
    for name in nfqws ip2net mdig; do
        printf '%s\n' "$name" > "$root/$name"
    done
    tar -czf "$TEST_DIR/zapret.tar.gz" -C "$TEST_DIR/source" zapret-v99
    ( cd "$TEST_DIR/source" && sha256sum zapret-v99/binaries/linux-x86_64/{nfqws,ip2net,mdig} ) > "$TEST_DIR/sha256sum.txt"
}

curl() {
    local out="" src
    while (( $# )); do
        if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi
    done
    [[ "$out" == *sha256sum.txt ]] && src="$TEST_DIR/sha256sum.txt" || src="$TEST_DIR/zapret.tar.gz"
    cp "$src" "$out"
}

# shellcheck disable=SC2034
ZAPRET_VER=v99
make_zapret_archive
printf 'tampered\n' >> "$TEST_DIR/source/zapret-v99/binaries/linux-x86_64/nfqws"
tar -czf "$TEST_DIR/zapret.tar.gz" -C "$TEST_DIR/source" zapret-v99
STAGING="$TEST_DIR/staging-bad-hash"
mkdir -p "$STAGING"
if ( fetch_zapret linux-x86_64 ) >/dev/null 2>&1; then
    printf 'FAIL: damaged binary passed checksum validation\n' >&2
    exit 1
fi
printf 'PASS: damaged zapret binary is rejected\n'

make_zapret_archive
grep -v '/mdig$' "$TEST_DIR/sha256sum.txt" > "$TEST_DIR/sums.tmp"
mv "$TEST_DIR/sums.tmp" "$TEST_DIR/sha256sum.txt"
STAGING="$TEST_DIR/staging-missing-sum"
mkdir -p "$STAGING"
if ( fetch_zapret linux-x86_64 ) >/dev/null 2>&1; then
    printf 'FAIL: missing checksum entry was accepted\n' >&2
    exit 1
fi
printf 'PASS: missing checksum entry is rejected\n'

make_flowseal_archive() {
    local variant="$1"
    rm -rf "$TEST_DIR/flowseal-source"
    mkdir -p "$TEST_DIR/flowseal-source"
    printf '@echo off\n"%%BIN%%winws.exe" --wf-tcp=443\n' > "$TEST_DIR/flowseal-source/general.bat"
    [[ "$variant" == no-bin ]] || mkdir -p "$TEST_DIR/flowseal-source/bin"
    [[ "$variant" == no-lists ]] || mkdir -p "$TEST_DIR/flowseal-source/lists"
    tar -czf "$TEST_DIR/flowseal.tar.gz" -C "$TEST_DIR" flowseal-source
}
curl() {
    local out=""
    while (( $# )); do
        if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi
    done
    cp "$TEST_DIR/flowseal.tar.gz" "$out"
}
for variant in no-bin no-lists; do
    make_flowseal_archive "$variant"
    STAGING="$TEST_DIR/staging-$variant"
    mkdir -p "$STAGING"
    if ( fetch_flowseal ) >/dev/null 2>&1; then
        printf 'FAIL: incomplete Flowseal archive (%s) was accepted\n' "$variant" >&2
        exit 1
    fi
done
printf 'PASS: incomplete Flowseal archives are rejected\n'

mkdir -p "$ZAPRET_BASE/init.d/sysv"
: > "$ZAPRET_BASE/init.d/sysv/functions"
if [[ "$(detect_occupant)" != zapret ]]; then
    printf 'FAIL: unmanaged zapret was not detected\n' >&2
    exit 1
fi
mkdir -p "$ZAPRET_BASE/zapret-sonar/lib"
: > "$ZAPRET_BASE/zapret-sonar/lib/install.conf"
[[ "$(detect_occupant)" == zapret-sonar ]]
printf 'PASS: installer distinguishes managed and unmanaged zapret\n'

export ZF_LIBRARY_MODE=1
export ZF_ZAPRET_BASE="$TEST_DIR/uninstall-root"
export ZF_BIN_DEST="$TEST_DIR/custom-bin"
mkdir -p "$ZF_ZAPRET_BASE/zapret-sonar" "$ZF_BIN_DEST"
: > "$ZF_ZAPRET_BASE/zapret-sonar/zapret-sonar"
: > "$ZF_ZAPRET_BASE/zapret-sonar/zapret-sonar-tui"
ln -s "$ZF_ZAPRET_BASE/zapret-sonar/zapret-sonar" "$ZF_BIN_DEST/sonar"
ln -s /foreign/command "$ZF_BIN_DEST/zapret-sonar"
ln -s "$ZF_ZAPRET_BASE/zapret-sonar/zapret-sonar-tui" "$ZF_BIN_DEST/sonar-tui"
# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
[[ "$(_zf_remove_command_links)" == 2 ]]
[[ ! -e "$ZF_BIN_DEST/sonar" && ! -e "$ZF_BIN_DEST/sonar-tui" ]]
[[ "$(readlink "$ZF_BIN_DEST/zapret-sonar")" == /foreign/command ]]
printf 'PASS: uninstall removes only owned links from custom BIN_DEST\n'
