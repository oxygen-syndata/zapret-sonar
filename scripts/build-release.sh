#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(sed -n 's/^version=//p' "$ROOT/RELEASE")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'invalid RELEASE version\n' >&2; exit 1; }
grep -qx "ZF_VERSION=\"$VERSION\"" "$ROOT/zapret-sonar" || { printf 'version mismatch\n' >&2; exit 1; }

OUT="${1:-$ROOT/dist}"
NAME="zapret-sonar-v$VERSION"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT" "$STAGE/$NAME/lib"
install -m 644 "$ROOT/RELEASE" "$STAGE/$NAME/RELEASE"
install -m 755 "$ROOT/zapret-sonar" "$ROOT/zapret-sonar-tui" "$STAGE/$NAME/"
install -m 644 "$ROOT/lib/"*.sh "$STAGE/$NAME/lib/"
tar -czf "$OUT/$NAME.tar.gz" -C "$STAGE" "$NAME"
( cd "$OUT" && sha256sum "$NAME.tar.gz" > SHA256SUMS )
printf '%s\n%s\n' "$OUT/$NAME.tar.gz" "$OUT/SHA256SUMS"
