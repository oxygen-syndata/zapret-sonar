#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

source "$PROJECT_DIR/lib/flowseal.sh"

mkdir -p "$TEST_DIR/source/bin" "$TEST_DIR/source/lists" "$TEST_DIR/old"
printf '@echo off\n"%%BIN%%winws.exe" --wf-tcp=443\n' > "$TEST_DIR/source/general (ALT1).bat"
: > "$TEST_DIR/source/bin/fake.bin"
printf 'new.example\n' > "$TEST_DIR/source/lists/list-general.txt"
printf '203.0.113.5/32\n203.0.113.9/32\n' > "$TEST_DIR/source/lists/ipset-all.txt"
printf '203.0.113.113/32\n' > "$TEST_DIR/old/ipset-all.txt"
printf 'old.example\n' > "$TEST_DIR/old/list-general-user.txt"
printf 'old-exclude.example\n' > "$TEST_DIR/old/list-exclude-user.txt"

zf_prepare_flowseal_tree "$TEST_DIR/source" "$TEST_DIR/stage" "$TEST_DIR/old"

[[ -f "$TEST_DIR/stage/strategies/general (ALT1).bat" ]]
[[ -f "$TEST_DIR/stage/bin/fake.bin" ]]
[[ "$(cat "$TEST_DIR/stage/lists/list-general-user.txt")" == old.example ]]
[[ "$(cat "$TEST_DIR/stage/lists/list-exclude-user.txt")" == old-exclude.example ]]
[[ "$(tr -d '\r' < "$TEST_DIR/stage/lists/ipset-all.txt")" == 203.0.113.113/32 ]]
[[ -f "$TEST_DIR/stage/lists/ipset-all.txt.backup" ]]
[[ -f "$TEST_DIR/stage/lists/ipset-exclude-user.txt" ]]

printf 'PASS: Flowseal staging preserves user lists and ipset mode\n'

mkdir -p "$TEST_DIR/releases"
for release in old active failed extra; do
    mkdir -p "$TEST_DIR/releases/$release"
done
ln -s ".flowseal-releases/old" "$TEST_DIR/current"
zf_restore_flowseal_tree "$TEST_DIR/current" ".flowseal-releases/active"
[[ "$(readlink "$TEST_DIR/current")" == ".flowseal-releases/active" ]]
zf_remove_flowseal_release "$TEST_DIR/releases" "$TEST_DIR/releases/failed"
[[ ! -e "$TEST_DIR/releases/failed" ]]
zf_prune_flowseal_releases "$TEST_DIR/releases" "$TEST_DIR/releases/active" ".flowseal-releases/old"
[[ -d "$TEST_DIR/releases/active" && -d "$TEST_DIR/releases/old" && ! -e "$TEST_DIR/releases/extra" ]]

printf 'PASS: rollback and pruning preserve active/previous releases\n'
