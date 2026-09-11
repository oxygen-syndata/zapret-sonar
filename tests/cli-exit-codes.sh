#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    exec sudo -n -- bash "$0"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

base="$TEST_DIR/zapret"
tree="$base/flowseal-current"
fake_bin="$TEST_DIR/bin"
mkdir -p "$tree/strategies" "$tree/bin" "$tree/lists" "$base/nfq" "$TEST_DIR/run" "$TEST_DIR/cache" "$fake_bin"
printf '@echo off\ninvalid\n' > "$tree/strategies/general.bat"
printf '#!/usr/bin/env bash\nexit 1\n' > "$base/nfq/nfqws"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_bin/curl"
printf '#!/usr/bin/env bash\nexit 23\n' > "$fake_bin/systemctl"
printf '#!/usr/bin/env bash\nexit 24\n' > "$fake_bin/journalctl"
printf '#!/usr/bin/env bash\nexit 23\n' > "$fake_bin/sudo"
chmod +x "$base/nfq/nfqws" "$fake_bin/"*

run_cli() {
    set +e
    CLI_OUTPUT=$(env PATH="$fake_bin:$PATH" \
        ZF_ZAPRET_BASE="$base" \
        ZF_FLOWSEAL_CURRENT="$tree" \
        ZF_RUNTIME_DIR="$TEST_DIR/run" \
        ZF_UPDATE_CACHE_DIR="$TEST_DIR/cache" \
        "$PROJECT_DIR/zapret-sonar" "$@" 2>&1)
    CLI_RC=$?
    set -e
}

run_cli check --json
(( CLI_RC == 1 ))
jq -e '.command == "check" and (.ok | not) and .failed == 7' <<< "$CLI_OUTPUT" >/dev/null

run_cli validate --json
(( CLI_RC == 1 ))
jq -e '.command == "validate" and (.ok | not) and .summary.failed == 1' <<< "$CLI_OUTPUT" >/dev/null

run_cli doctor
(( CLI_RC == 1 ))
[[ "$CLI_OUTPUT" == *'Итог: FAIL'* ]]

run_cli _render general.bat off none
(( CLI_RC != 0 ))
(( EUID != 0 )) || [[ "$CLI_OUTPUT" != *'требует root'* ]]

run_cli _apply general.bat off none
(( CLI_RC != 0 ))
(( EUID != 0 )) || [[ "$CLI_OUTPUT" != *'требует root'* ]]

run_cli restart
(( CLI_RC == 23 ))

run_cli log
(( CLI_RC == 24 ))

cat > "$TEST_DIR/cache/update-check" <<EOF
check_state=ok
flowseal_local=1.10.2
flowseal_remote=1.10.2
zapret_local=v72.13
zapret_remote=v72.13
sonar_remote=9.9.9
last_check=$(date +%s)
EOF
tty_command=$(printf '%q ' env PATH="$fake_bin:$PATH" \
    ZF_ZAPRET_BASE="$base" \
    ZF_FLOWSEAL_CURRENT="$tree" \
    ZF_RUNTIME_DIR="$TEST_DIR/run" \
    ZF_UPDATE_CACHE_DIR="$TEST_DIR/cache" \
    "$PROJECT_DIR/zapret-sonar" doctor)
set +e
CLI_OUTPUT=$(script -qec "$tty_command" /dev/null 2>&1)
CLI_RC=$?
set -e
(( CLI_RC == 1 ))
[[ "$CLI_OUTPUT" == *'Доступно обновление'* ]]

printf 'PASS: CLI preserves command exit codes through final notification handling\n'
