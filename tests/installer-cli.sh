#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

help=$(bash "$PROJECT_DIR/install.sh" --help)
[[ "$help" == *'--dry-run'* && "$help" == *'--non-interactive'* ]]
if bash "$PROJECT_DIR/install.sh" --unknown >/dev/null 2>&1; then
    printf 'FAIL: installer accepted an unknown option\n' >&2
    exit 1
fi
printf 'PASS: installer CLI documents modes and rejects unknown options\n'
