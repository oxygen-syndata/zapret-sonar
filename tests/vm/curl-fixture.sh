#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${ZF_VM_UPSTREAM_MANIFEST:-$SCRIPT_DIR/upstream.tsv}"

out=""
url=""
url_count=0
while (( $# > 0 )); do
    case "$1" in
        -o|--output)
            (( $# >= 2 )) || exit 2
            out="$2"
            shift 2
            ;;
        -f|-s|-S|-L|--fail|--silent|--show-error|--location|--retry-all-errors) shift ;;
        --retry)
            (( $# >= 2 )) || exit 2
            [[ "$2" =~ ^[0-9]+$ ]] || exit 2
            shift 2
            ;;
        -fsSL) shift ;;
        -*) printf 'unsupported curl fixture option: %s\n' "$1" >&2; exit 2 ;;
        *) url="$1"; url_count=$((url_count + 1)); shift ;;
    esac
done

[[ -n "$out" && -n "$url" && "$url_count" == 1 ]] || exit 2
source_file=$(awk -F '\t' -v url="$url" '$1 !~ /^#/ && $3 == url { print $2; found=1; exit } END { if (!found) exit 1 }' "$MANIFEST") || {
    printf 'unexpected VM fixture URL: %s\n' "$url" >&2
    exit 22
}

expected=$(awk -F '\t' -v url="$url" '$1 !~ /^#/ && $3 == url { print $4; exit }' "$MANIFEST")
actual=$(sha256sum "${ZF_VM_INPUT_DIR:?}/$source_file" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || { printf 'VM fixture checksum mismatch: %s\n' "$source_file" >&2; exit 1; }

install -m 0644 "${ZF_VM_INPUT_DIR:?}/$source_file" "$out"
