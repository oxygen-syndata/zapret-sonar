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
tree="$ZF_ZAPRET_BASE/flowseal-current"
mkdir -p "$tree/strategies" "$tree/bin" "$tree/lists" "$ZF_ZAPRET_BASE/nfq" "$ZF_RUNTIME_DIR"
printf '@echo off\n"%%BIN%%winws.exe" --wf-tcp=443 --dpi-desync=fake\n' > "$tree/strategies/general.bat"
printf '@echo off\ninvalid\n' > "$tree/strategies/general (BROKEN).bat"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ZF_ZAPRET_BASE/nfq/nfqws"
chmod +x "$ZF_ZAPRET_BASE/nfq/nfqws"

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
before=$(sha256sum "$tree/strategies/"*.bat)
set +e
json=$(cmd_validate --json); rc=$?
set -e
(( rc == 1 ))
jq -e '.schema_version == 1 and .command == "validate" and (.ok | not) and .summary.total == 2 and .summary.failed == 1' <<< "$json" >/dev/null
[[ "$before" == "$(sha256sum "$tree/strategies/"*.bat)" ]]
printf 'PASS: validate checks every strategy without mutation\n'
