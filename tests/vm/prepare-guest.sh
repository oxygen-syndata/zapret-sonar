#!/usr/bin/env bash
set -euo pipefail

image_id="${1:?image id is required}"

case "$image_id" in
    ubuntu-*)
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        while IFS= read -r source_file; do
            sed -i 's|http://archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g; s|http://security.ubuntu.com/ubuntu|https://security.ubuntu.com/ubuntu|g' "$source_file"
        done < <(find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -print)
        missing=()
        for package in bash curl tar coreutils findutils grep sed util-linux iproute2 systemd nftables iptables ipset jq; do
            dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii ' || missing+=("$package")
        done
        if (( ${#missing[@]} > 0 )); then
            # The pinned release image already contains signed package indexes.
            # Install only missing packages; do not turn image preparation into
            # a full distro update on every harness change.
            apt-get -qq -o Acquire::ForceIPv4=true -o Acquire::Retries=2 \
                -o Acquire::https::Timeout=20 -o Dpkg::Use-Pty=0 \
                --no-upgrade --no-install-recommends install -y "${missing[@]}"
        fi
        ;;
    arch-*)
        # Keep the rolling distribution reproducible by provisioning from the
        # dated archive snapshot matching the pinned cloud image.
        printf 'Server = https://archive.archlinux.org/repos/2026/09/01/$repo/os/$arch\n' > /etc/pacman.d/mirrorlist
        pacman -Syyu --noconfirm --needed --noprogressbar \
            bash curl tar coreutils findutils grep sed util-linux iproute2 \
            systemd nftables iptables ipset jq
        ;;
    fedora-*)
        missing=()
        for package in bash curl tar coreutils findutils grep sed util-linux iproute systemd nftables iptables-nft ipset jq libselinux-utils policycoreutils; do
            rpm -q "$package" >/dev/null 2>&1 || missing+=("$package")
        done
        if (( ${#missing[@]} > 0 )); then
            # The Fedora release repository is immutable; do not mix a full
            # distribution update into preparation of the pinned cloud image.
            dnf -y --disablerepo='*' --enablerepo=fedora \
                --setopt=install_weak_deps=False install "${missing[@]}"
        fi
        ;;
    *)
        printf 'unsupported prepared image: %s\n' "$image_id" >&2
        exit 1
        ;;
esac

command -v bash curl jq nft iptables ip6tables ipset systemctl >/dev/null
[[ "$image_id" != fedora-* ]] || command -v getenforce restorecon >/dev/null
