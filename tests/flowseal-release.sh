#!/usr/bin/env bash
set -euo pipefail

FLOWSEAL_VER="${FLOWSEAL_VER:-1.10.2}"
ZAPRET_VER="${ZAPRET_VER:-v72.13}"
ARCH="${ARCH:-linux-x86_64}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

curl -fsSL --retry 5 --retry-all-errors -o "$TEST_DIR/flowseal.tar.gz" \
    "https://codeload.github.com/Flowseal/zapret-discord-youtube/tar.gz/refs/tags/$FLOWSEAL_VER"
curl -fsSL --retry 5 --retry-all-errors -o "$TEST_DIR/zapret.tar.gz" \
    "https://github.com/bol-van/zapret/releases/download/$ZAPRET_VER/zapret-$ZAPRET_VER.tar.gz"
curl -fsSL --retry 5 --retry-all-errors -o "$TEST_DIR/sha256sum.txt" \
    "https://github.com/bol-van/zapret/releases/download/$ZAPRET_VER/sha256sum.txt"
tar -xzf "$TEST_DIR/flowseal.tar.gz" -C "$TEST_DIR"
tar -xzf "$TEST_DIR/zapret.tar.gz" -C "$TEST_DIR"

flowseal=$(find "$TEST_DIR" -maxdepth 2 -name 'general*.bat' -printf '%h\n' | head -1)
nfqws="$TEST_DIR/zapret-$ZAPRET_VER/binaries/$ARCH/nfqws"
[[ -d "$flowseal/bin" && -d "$flowseal/lists" && -x "$nfqws" ]]
grep -Fq "binaries/$ARCH/nfqws" "$TEST_DIR/sha256sum.txt"
( cd "$TEST_DIR" && sha256sum -c --ignore-missing --quiet sha256sum.txt )

# shellcheck source=../lib/translate.sh
source "$PROJECT_DIR/lib/translate.sh"
# shellcheck source=../lib/flowseal.sh
source "$PROJECT_DIR/lib/flowseal.sh"
zf_prepare_flowseal_tree "$flowseal" "$TEST_DIR/prepared"
flowseal="$TEST_DIR/prepared"
count=0
for bat in "$flowseal"/strategies/general*.bat; do
    zf_translate "$bat" "$flowseal/bin" "$flowseal/lists" off
    while IFS= read -r file; do
        [[ -e "$file" ]] || { printf 'missing reference: %s (%s)\n' "$file" "$bat" >&2; exit 1; }
    done < <(zf_referenced_files)
    zf_verify "$nfqws"
    count=$((count + 1))
done
(( count > 0 ))
printf 'PASS: translated and verified %d pinned Flowseal strategies\n' "$count"
