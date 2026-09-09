#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

source "$PROJECT_DIR/lib/self-update.sh"
[[ "$ZF_SELF_REPO" == zero-oxygen/zapret-sonar ]]
make_tree() {
    local version="$1" root
    root="$TEST_DIR/zapret-sonar-v$version"
    rm -rf "$root"; mkdir -p "$root/lib"
    printf 'format=1\nversion=%s\n' "$version" > "$root/RELEASE"
    printf '#!/usr/bin/env bash\nZF_VERSION="%s"\nprintf "zapret-sonar %%s\\n" "$ZF_VERSION"\n' "$version" > "$root/zapret-sonar"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/zapret-sonar-tui"
    for file in translate zconfig health flowseal self-update; do printf '#!/usr/bin/env bash\n' > "$root/lib/$file.sh"; done
    chmod +x "$root/zapret-sonar" "$root/zapret-sonar-tui"
    tar -czf "$TEST_DIR/zapret-sonar-v$version.tar.gz" -C "$TEST_DIR" "zapret-sonar-v$version"
}

make_tree 1.3.0
asset=zapret-sonar-v1.3.0.tar.gz
sha256sum "$TEST_DIR/$asset" | sed "s|$TEST_DIR/||" > "$TEST_DIR/SHA256SUMS"
zf_self_verify_checksum "$TEST_DIR/SHA256SUMS" "$TEST_DIR/$asset" "$asset"
zf_self_validate_archive "$TEST_DIR/$asset" 1.3.0
zf_self_validate_tree "$TEST_DIR/zapret-sonar-v1.3.0" 1.3.0
printf 'tampered\n' >> "$TEST_DIR/$asset"
! zf_self_verify_checksum "$TEST_DIR/SHA256SUMS" "$TEST_DIR/$asset" "$asset"

rm -rf "$TEST_DIR/zapret-sonar-v1.3.0"
make_tree 1.3.0
ln -s /etc/passwd "$TEST_DIR/zapret-sonar-v1.3.0/lib/evil.sh"
tar -czf "$TEST_DIR/evil.tar.gz" -C "$TEST_DIR" zapret-sonar-v1.3.0
! zf_self_validate_archive "$TEST_DIR/evil.tar.gz" 1.3.0

rm "$TEST_DIR/zapret-sonar-v1.3.0/lib/evil.sh"
printf '#!/usr/bin/env bash\n' > "$TEST_DIR/zapret-sonar-v1.3.0/lib/future.sh"
tar -czf "$TEST_DIR/future.tar.gz" -C "$TEST_DIR" zapret-sonar-v1.3.0
zf_self_validate_archive "$TEST_DIR/future.tar.gz" 1.3.0

install_root="$TEST_DIR/install"
mkdir -p "$install_root/releases/old" "$install_root/releases/new" "$install_root/releases/extra"
ln -s releases/old "$install_root/current"
zf_self_switch "$install_root" new
[[ "$(readlink "$install_root/current")" == releases/new ]]
zf_self_prune "$install_root" new old
[[ -d "$install_root/releases/new" && -d "$install_root/releases/old" && ! -e "$install_root/releases/extra" ]]
printf 'PASS: self-update validates artifacts and switches releases atomically\n'
