#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export ZF_LIBRARY_MODE=1
export ZF_ZAPRET_BASE="$TEST_DIR/private-install-path"
export ZF_ZAPRET_CONFIG="$ZF_ZAPRET_BASE/config"
export ZF_RUNTIME_DIR="$TEST_DIR/run"
export ZF_UPDATE_CACHE_DIR="$TEST_DIR/cache"
mkdir -p "$ZF_ZAPRET_BASE/nfq" "$ZF_ZAPRET_BASE/flowseal-current/strategies" \
    "$ZF_ZAPRET_BASE/flowseal-current/bin" "$ZF_ZAPRET_BASE/flowseal-current/lists" "$ZF_RUNTIME_DIR"
printf '#!/usr/bin/env bash\nprintf "github version v72.13 (test)\\n"\n' > "$ZF_ZAPRET_BASE/nfq/nfqws"
chmod +x "$ZF_ZAPRET_BASE/nfq/nfqws"
printf '# zapret-sonar-strategy: SECRET-STRATEGY.bat\n# zapret-sonar-gamefilter: off\nSECRET_TOKEN=do-not-export\n' > "$ZF_ZAPRET_CONFIG"
printf 'private.example\n' > "$ZF_ZAPRET_BASE/flowseal-current/lists/list-general-user.txt"

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
systemctl() { [[ "$1" == is-active ]] && printf 'failed\n'; }
# shellcheck disable=SC2034
_zf_collect_validation() { ZF_VALIDATE_TOTAL=2; ZF_VALIDATE_PASSED=1; ZF_VALIDATE_FAILED=1; return 1; }

output="$TEST_DIR/diagnostic.json"
cmd_export_diagnostic --output "$output" 2>/dev/null
jq -e '.schema_version == 1 and .kind == "zapret-sonar-diagnostic" and .validation.failed == 1 and (.privacy.logs_included | not)' "$output" >/dev/null
[[ "$(stat -c %a "$output")" == 600 ]]
if grep -Eq 'do-not-export|private\.example|private-install-path' "$output"; then
    printf 'FAIL: diagnostic contains private source data\n' >&2
    exit 1
fi
printf 'PASS: diagnostic export is valid and excludes private source data\n'
