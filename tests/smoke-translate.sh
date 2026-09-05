#!/usr/bin/env bash
# Smoke-тест: проверяет что translate.sh парсит .bat без ошибок
# и что результат проходит санитизацию.
#
# Не требует установки zapret — тестит только парсер.
# Запуск: bash tests/smoke-translate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Минимальный .bat для проверки трансляции
BAT_DIR=$(mktemp -d)
trap 'rm -rf "$BAT_DIR"' EXIT

cat > "$BAT_DIR/general (TEST).bat" <<'BAT'
@echo off
set WF_TCP=443
set WF_UDP=443,50000-50100

"%BIN%winws.exe" ^
  --wf-tcp=443 --wf-udp=443,50000-50100 ^
  --qnum=200 --dpi-desync=fake,split2 --dpi-desync-tls=ja3_sni ^
  --dpi-desync-fake-tls=0x1234567890ab ^
  --hostlist="%LISTS%list-general.txt" ^
  --hostlist-exclude="%LISTS%list-exclude.txt" ^
  --new ^
  --dpi-desync=fake,split2 ^
  --wf-udp=443 --wf-raw=70726f78785f70726f7879

exit /b
BAT

# Поддельные .bin и списки (пустые) — пути должны совпадать с %BIN%/%LISTS%
BIN_DIR="$BAT_DIR/bin"
LISTS_DIR="$BAT_DIR/lists"
mkdir -p "$BIN_DIR" "$LISTS_DIR"
: > "$LISTS_DIR/list-general.txt"
: > "$LISTS_DIR/list-exclude.txt"

# Парсим
source "$PROJECT_DIR/lib/translate.sh"

ZF_PORTS_TCP=""
ZF_PORTS_UDP=""
ZF_OPT=""

if zf_translate "$BAT_DIR/general (TEST).bat" "$BIN_DIR" "$LISTS_DIR" "off" 2>&1; then
    echo "PASS: translate succeeded"
    echo "  TCP: $ZF_PORTS_TCP"
    echo "  UDP: $ZF_PORTS_UDP"
    echo "  OPT: ${ZF_OPT:0:80}..."
else
    echo "FAIL: translate returned error"
    exit 1
fi

# Проверка санитизации: ZF_OPT не должен содержать метасимволы
if [[ "$ZF_OPT" == *'$'* || "$ZF_OPT" == *'`'* || "$ZF_OPT" == *';'* ]]; then
    echo "FAIL: ZF_OPT contains shell metacharacters"
    exit 1
fi
echo "PASS: ZF_OPT sanitized"

# Проверка структуры: должны быть --qnum и --dpi-desync
if [[ "$ZF_OPT" != *"--qnum=200"* ]]; then
    echo "FAIL: --qnum missing from ZF_OPT"
    exit 1
fi
if [[ "$ZF_OPT" != *"--dpi-desync=fake"* ]]; then
    echo "FAIL: --dpi-desync missing from ZF_OPT"
    exit 1
fi
echo "PASS: expected arguments present"

# Проверка referenced_files
if zf_referenced_files | grep -q "list-general.txt"; then
    echo "PASS: hostlist detected"
else
    echo "FAIL: hostlist not detected"
    exit 1
fi

echo ""
echo "All smoke tests passed."
