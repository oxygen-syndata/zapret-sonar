#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_BIN=$(command -v bash)

help=$(bash "$PROJECT_DIR/install.sh" --help)
[[ "$help" == *'--dry-run'* && "$help" == *'--non-interactive'* ]]
if bash "$PROJECT_DIR/install.sh" --unknown >/dev/null 2>&1; then
    printf 'FAIL: installer accepted an unknown option\n' >&2
    exit 1
fi
printf 'PASS: installer CLI documents modes and rejects unknown options\n'

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/zapret"
for command in curl tar sha256sum systemctl flock stat install find grep sed readlink sort head tail wc mktemp iptables ip6tables dirname; do
    target=$(command -v "$command" 2>/dev/null || true)
    if [[ -n "$target" ]]; then ln -s "$target" "$TEST_DIR/bin/$command"
    else printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/bin/$command"; chmod +x "$TEST_DIR/bin/$command"
    fi
done
set +e
output=$(PATH="$TEST_DIR/bin" ZF_INSTALL_LIBRARY_MODE=1 ZAPRET_BASE="$TEST_DIR/zapret" \
    SERVICE_NAME=zapret-installer-test "$BASH_BIN" -c 'source "$1"; INSTALL_DRY_RUN=1; preflight' _ "$PROJECT_DIR/install.sh" 2>&1)
rc=$?
set -e
(( rc != 0 ))
[[ "$output" == *'для iptables backend нужна утилита ipset'* ]]
printf 'PASS: installer requires ipset for the iptables backend\n'

printf 'FWTYPE=iptables\n' > "$TEST_DIR/zapret/config"
ln -s "$(command -v nft)" "$TEST_DIR/bin/nft"
set +e
output=$(PATH="$TEST_DIR/bin" ZF_INSTALL_LIBRARY_MODE=1 ZAPRET_BASE="$TEST_DIR/zapret" \
    SERVICE_NAME=zapret-installer-test MIGRATE_ZAPRET=1 "$BASH_BIN" \
    -c 'source "$1"; INSTALL_DRY_RUN=1; preflight' _ "$PROJECT_DIR/install.sh" 2>&1)
rc=$?
set -e
(( rc != 0 ))
[[ "$output" == *'для iptables backend нужна утилита ipset'* ]]
printf 'PASS: preserved iptables config requires ipset even when nft is installed\n'

printf '  export FWTYPE=iptables\n' > "$TEST_DIR/zapret/config"
set +e
output=$(PATH="$TEST_DIR/bin" ZF_INSTALL_LIBRARY_MODE=1 ZAPRET_BASE="$TEST_DIR/zapret" \
    SERVICE_NAME=zapret-installer-test MIGRATE_ZAPRET=1 "$BASH_BIN" \
    -c 'source "$1"; INSTALL_DRY_RUN=1; preflight' _ "$PROJECT_DIR/install.sh" 2>&1)
rc=$?
set -e
(( rc != 0 ))
[[ "$output" == *'для iptables backend нужна утилита ipset'* ]]
printf 'PASS: exported preserved FWTYPE is parsed without unsafe sourcing\n'

printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/bin/ipset"
chmod +x "$TEST_DIR/bin/ipset"
rm "$TEST_DIR/bin/ip6tables"
set +e
output=$(PATH="$TEST_DIR/bin" ZF_INSTALL_LIBRARY_MODE=1 ZAPRET_BASE="$TEST_DIR/zapret" \
    SERVICE_NAME=zapret-installer-test MIGRATE_ZAPRET=1 "$BASH_BIN" \
    -c 'source "$1"; INSTALL_DRY_RUN=1; preflight' _ "$PROJECT_DIR/install.sh" 2>&1)
rc=$?
set -e
(( rc != 0 ))
[[ "$output" == *'для iptables backend нужна утилита ip6tables'* ]]
printf 'PASS: preserved iptables config requires ip6tables\n'

printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/bin/ip6tables"
chmod +x "$TEST_DIR/bin/ip6tables"
mkdir -p "$TEST_DIR/zapret/init.d/sysv"
: > "$TEST_DIR/zapret/init.d/sysv/functions"
: > "$TEST_DIR/zapret/config"
output=$(PATH="$TEST_DIR/bin" ZF_INSTALL_LIBRARY_MODE=1 ZAPRET_BASE="$TEST_DIR/zapret" \
    SERVICE_NAME=zapret-installer-test MIGRATE_ZAPRET=1 "$BASH_BIN" \
    -c 'source "$1"; INSTALL_DRY_RUN=1; preflight' _ "$PROJECT_DIR/install.sh" 2>&1)
[[ "$output" == *'включена явная миграция существующей zapret v1'* ]]
printf 'PASS: preserved config without FWTYPE uses upstream-style backend detection\n'

rm "$TEST_DIR/bin/ipset"
set +e
output=$(PATH="$TEST_DIR/bin" ZF_INSTALL_LIBRARY_MODE=1 ZAPRET_BASE="$TEST_DIR/zapret" \
    SERVICE_NAME=zapret-installer-test MIGRATE_ZAPRET=1 "$BASH_BIN" \
    -c 'source "$1"; install_kernel_at_least_4_16() { return 1; }; INSTALL_DRY_RUN=1; preflight' \
    _ "$PROJECT_DIR/install.sh" 2>&1)
rc=$?
set -e
(( rc != 0 ))
[[ "$output" == *'для iptables backend нужна утилита ipset'* ]]
printf 'PASS: legacy kernels follow upstream iptables auto-detection\n'
