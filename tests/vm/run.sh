#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE_MANIFEST="$SCRIPT_DIR/images.tsv"
UPSTREAM_MANIFEST="$SCRIPT_DIR/upstream.tsv"
CACHE_DIR="${ZF_VM_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zapret-sonar/vm-images}"
INPUT_DIR="${ZF_VM_INPUT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zapret-sonar/vm-inputs}"
ARTIFACT_ROOT="${ZF_VM_ARTIFACT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zapret-sonar/vm-artifacts}"
PREPARED_DIR="$CACHE_DIR/prepared"
VM_MEMORY="${ZF_VM_MEMORY:-2048}"
VM_CPUS="${ZF_VM_CPUS:-2}"
SSH_TIMEOUT="${ZF_VM_SSH_TIMEOUT:-300}"
PROVISION_TIMEOUT="${ZF_VM_PROVISION_TIMEOUT:-900}"
LIFECYCLE_TIMEOUT="${ZF_VM_LIFECYCLE_TIMEOUT:-600}"
PREPARED_FORMAT_VERSION=3
QEMU_PID=""
WORK_DIR=""
SSH_USER=""
SSH_PORT=""
SSH_KEY=""
PROFILE=""
IMAGE_ID=""
IMAGE_FILE=""
IMAGE_URL=""
IMAGE_CHECKSUM=""
RUN_NONCE=""
SSH_OPTIONS=()
SCP_OPTIONS=()
PARALLEL_DIR=""
CHILD_PIDS=()

die() {
    printf 'VM harness error: %s\n' "$*" >&2
    exit 1
}

require_commands() {
    local command
    for command in curl cloud-localds flock git openssl qemu-img qemu-system-x86_64 sha256sum sort stat ssh ssh-keygen scp tar timeout; do
        command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
    done
    [[ -r /dev/kvm && -w /dev/kvm ]] || die '/dev/kvm is not accessible for hardware virtualization'
}

prepare_lock() {
    local runtime_dir="${XDG_RUNTIME_DIR:-/tmp/zapret-sonar-vm-$UID}"
    [[ ! -L "$runtime_dir" ]] || die "unsafe runtime directory: $runtime_dir"
    install -d -m 0700 "$runtime_dir"
    [[ "$(stat -c %u "$runtime_dir")" == "$UID" ]] || die "runtime directory is not owned by uid $UID"
    local lock="$runtime_dir/harness.lock"
    [[ ! -L "$lock" ]] || die "lock must not be a symlink: $lock"
    exec 9>"$lock"
    flock -n 9 || die 'another VM harness run is active'
}

manifest_row() {
    local manifest="$1" key="$2"
    awk -F '\t' -v key="$key" '$1 == key { print; found=1; exit } END { if (!found) exit 1 }' "$manifest"
}

validate_manifests() {
    local profile image_id image_file image_url image_checksum ssh_user ssh_port extra
    local name file url checksum
    local profiles=" " ports=" " images=" " names=" " files=" " profile_count=0 count=0
    while IFS=$'\t' read -r profile image_id image_file image_url image_checksum ssh_user ssh_port extra; do
        [[ -n "$profile" && "$profile" != \#* ]] || continue
        [[ -z "${extra:-}" && "$profile" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid VM profile manifest row"
        [[ "$image_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$image_file" == "${image_file##*/}" ]] \
            || die "invalid VM image manifest path"
        [[ "$image_url" == https://* && "$image_checksum" =~ ^[0-9a-f]{64}$ ]] \
            || die "invalid VM image manifest input"
        [[ "$ssh_user" =~ ^[a-z_][a-z0-9_-]*$ && "$ssh_port" =~ ^[0-9]+$ && "$ssh_port" -ge 1024 && "$ssh_port" -le 65535 ]] \
            || die "invalid VM SSH manifest input"
        [[ "$profiles" != *" $profile "* && "$ports" != *" $ssh_port "* ]] || die "duplicate VM profile or SSH port"
        profiles+="$profile "; ports+="$ssh_port "; images+="$image_id "; profile_count=$((profile_count + 1))
    done < "$IMAGE_MANIFEST"
    (( profile_count > 0 )) || die 'VM image manifest is empty'

    while IFS=$'\t' read -r name file url checksum extra; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        [[ -z "${extra:-}" && "$name" =~ ^[a-z0-9][a-z0-9-]*$ && "$file" == "${file##*/}" ]] \
            || die "invalid VM upstream manifest row"
        [[ "$url" == https://* && "$checksum" =~ ^[0-9a-f]{64}$ ]] || die "invalid VM upstream manifest input"
        [[ "$names" != *" $name "* && "$files" != *" $file "* ]] || die "duplicate VM upstream name or file"
        names+="$name "; files+="$file "; count=$((count + 1))
    done < "$UPSTREAM_MANIFEST"
    [[ "$count" == 3 ]] || die "unexpected number of VM upstream inputs: $count"
}

download_verified() {
    local target="$1" url="$2" expected="$3" actual
    if [[ -f "$target" ]]; then
        actual=$(sha256sum "$target" | awk '{print $1}')
        [[ "$actual" == "$expected" ]] && return 0
        die "checksum mismatch for cached file: $target"
    fi
    printf 'Downloading %s\n' "$(basename "$target")"
    curl -fL --retry 5 --retry-all-errors -o "$target.part" "$url"
    actual=$(sha256sum "$target.part" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || {
        rm -f "$target.part"
        die "checksum mismatch after download: $target"
    }
    mv "$target.part" "$target"
}

prepare_inputs() {
    install -d -m 0755 "$CACHE_DIR" "$INPUT_DIR"
    local name file url checksum
    while IFS=$'\t' read -r name file url checksum; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        download_verified "$INPUT_DIR/$file" "$url" "$checksum"
    done < "$UPSTREAM_MANIFEST"
}

stop_vm() {
    [[ -n "$QEMU_PID" ]] || return 0
    if kill -0 "$QEMU_PID" 2>/dev/null; then
        if [[ -n "$SSH_USER" && -n "$SSH_PORT" && -n "$SSH_KEY" ]]; then
            timeout 10 ssh "${SSH_OPTIONS[@]}" "$SSH_USER@127.0.0.1" 'sudo poweroff' >/dev/null 2>&1 || true
        fi
        local remaining=20
        while (( remaining > 0 )); do
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 0.5
            remaining=$((remaining - 1))
        done
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            kill -TERM "$QEMU_PID" 2>/dev/null || true
            remaining=20
            while (( remaining > 0 )); do
                kill -0 "$QEMU_PID" 2>/dev/null || break
                sleep 0.25
                remaining=$((remaining - 1))
            done
        fi
        kill -KILL "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    QEMU_PID=""
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    local child
    for child in "${CHILD_PIDS[@]}"; do
        kill -TERM "$child" 2>/dev/null || true
    done
    for child in "${CHILD_PIDS[@]}"; do
        wait "$child" 2>/dev/null || true
    done
    if (( rc != 0 )) && [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        collect_guest_artifacts || true
    fi
    stop_vm
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        if (( rc != 0 )); then
            local destination
            destination="$ARTIFACT_ROOT/${PROFILE:-unknown}-$(date -u +%Y%m%dT%H%M%SZ)"
            install -d -m 0700 "$destination"
            cp -a "$WORK_DIR/artifacts/." "$destination/" 2>/dev/null || true
            cp -a "$WORK_DIR/serial.log" "$destination/" 2>/dev/null || true
            cp -a "$WORK_DIR/qemu.log" "$destination/" 2>/dev/null || true
            cp -a "$WORK_DIR/provision.log" "$destination/" 2>/dev/null || true
            cp -a "$WORK_DIR/lifecycle.log" "$destination/" 2>/dev/null || true
            printf 'Failure artifacts: %s\n' "$destination" >&2
        fi
        rm -rf "$WORK_DIR"
    fi
    [[ -z "$PARALLEL_DIR" || ! -d "$PARALLEL_DIR" ]] || rm -rf -- "$PARALLEL_DIR"
    exit "$rc"
}

make_source_archive() {
    {
        git -C "$PROJECT_DIR" ls-files -z --cached
        printf '%s\0' \
            tests/vm/curl-fixture.sh tests/vm/guest.sh tests/vm/images.tsv \
            tests/vm/prepare-guest.sh tests/vm/run.sh tests/vm/upstream.tsv \
            tests/vm-manifests.sh
    } | sort -zu | tar --null -czf "$WORK_DIR/project.tar.gz" -C "$PROJECT_DIR" -T -
}

make_seed() {
    ssh-keygen -q -t ed25519 -N '' -f "$WORK_DIR/id_ed25519"
    SSH_KEY="$WORK_DIR/id_ed25519"
    local public_key instance_id
    public_key=$(<"$SSH_KEY.pub")
    instance_id="zapret-sonar-$PROFILE-$(date +%s)-$$"
    RUN_NONCE=$(openssl rand -hex 32)
    cat > "$WORK_DIR/user-data" <<EOF
#cloud-config
preserve_hostname: true
users:
  - default
  - name: zapret-test
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $public_key
ssh_pwauth: false
write_files:
  - path: /etc/zapret-sonar-vm-nonce
    permissions: '0400'
    owner: root:root
    content: $RUN_NONCE
EOF
cat > "$WORK_DIR/meta-data" <<EOF
instance-id: $instance_id
EOF
    cloud-localds "$WORK_DIR/seed.img" "$WORK_DIR/user-data" "$WORK_DIR/meta-data"
}

wait_for_ssh() {
    local deadline=$((SECONDS + SSH_TIMEOUT))
    until timeout --foreground 8 ssh "${SSH_OPTIONS[@]}" "$SSH_USER@127.0.0.1" true >/dev/null 2>&1; do
        kill -0 "$QEMU_PID" 2>/dev/null || die "QEMU exited before SSH became available"
        (( SECONDS < deadline )) || die "SSH did not become available within ${SSH_TIMEOUT}s"
        sleep 2
    done
    wait_for_cloud_init
    kill -0 "$QEMU_PID" 2>/dev/null || die 'QEMU exited after SSH became available'
    [[ "$(timeout --foreground 8 ssh "${SSH_OPTIONS[@]}" "$SSH_USER@127.0.0.1" 'sudo cat /etc/zapret-sonar-vm-nonce')" == "$RUN_NONCE" ]] \
        || die 'SSH endpoint did not return the per-run nonce'
}

wait_for_cloud_init() {
    local output rc
    set +e
    output=$(timeout --foreground 60 ssh "${SSH_OPTIONS[@]}" "$SSH_USER@127.0.0.1" \
        'sudo cloud-init status --wait' 2>&1)
    rc=$?
    set -e
    printf '%s\n' "$output"
    (( rc == 0 )) || die "cloud-init did not finish successfully (exit $rc)"
    [[ "$output" == *'status: done'* ]] || die 'cloud-init did not report done'
}

reboot_guest() {
    local old_boot_id="$1" deadline=$((SECONDS + SSH_TIMEOUT)) new_boot_id=""
    ssh_vm 10 'sudo systemctl reboot' >/dev/null 2>&1 || true
    until [[ -n "$new_boot_id" && "$new_boot_id" != "$old_boot_id" ]]; do
        kill -0 "$QEMU_PID" 2>/dev/null || die 'QEMU exited while rebooting the guest'
        (( SECONDS < deadline )) || die 'guest did not return with a new kernel boot ID'
        new_boot_id=$(timeout --foreground 8 ssh "${SSH_OPTIONS[@]}" "$SSH_USER@127.0.0.1" \
            'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
        [[ "$new_boot_id" != "$old_boot_id" ]] || sleep 2
    done
    wait_for_cloud_init
    [[ "$(timeout --foreground 8 ssh "${SSH_OPTIONS[@]}" "$SSH_USER@127.0.0.1" 'sudo cat /etc/zapret-sonar-vm-nonce')" == "$RUN_NONCE" ]] \
        || die 'rebooted SSH endpoint did not return the per-run nonce'
}

run_guest_phase() {
    local log="$WORK_DIR/lifecycle.log" rc
    printf 'Running lifecycle checks for %s\n' "$PROFILE"
    set +e
    timeout --foreground "$LIFECYCLE_TIMEOUT" ssh "${SSH_OPTIONS[@]}" "$SSH_USER@127.0.0.1" \
        "sudo env ZF_VM_PROFILE='$PROFILE' ZF_VM_INPUT_DIR='/home/$SSH_USER/zapret-sonar-vm/inputs' ZF_VM_RUN_DIR='/home/$SSH_USER/zapret-sonar-vm' timeout --foreground --kill-after=10 $((LIFECYCLE_TIMEOUT - 30)) bash '/home/$SSH_USER/zapret-sonar-vm/source/tests/vm/guest.sh' lifecycle" \
        >"$log" 2>&1
    rc=$?
    set -e
    if (( rc != 0 )); then
        printf 'Lifecycle failed for %s (exit %d); final log lines:\n' "$PROFILE" "$rc" >&2
        tail -n 80 "$log" >&2
    fi
    return "$rc"
}

copy_guest_inputs() {
    ssh_vm 30 'rm -rf "$HOME/zapret-sonar-vm" && mkdir -p "$HOME/zapret-sonar-vm/source" "$HOME/zapret-sonar-vm/inputs"'
    scp_vm 60 "$WORK_DIR/project.tar.gz" "$SSH_USER@127.0.0.1:zapret-sonar-vm/"
    local name file url checksum
    while IFS=$'\t' read -r name file url checksum; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        scp_vm 60 "$INPUT_DIR/$file" "$SSH_USER@127.0.0.1:zapret-sonar-vm/inputs/"
    done < "$UPSTREAM_MANIFEST"
    ssh_vm 30 'tar -xzf "$HOME/zapret-sonar-vm/project.tar.gz" -C "$HOME/zapret-sonar-vm/source"'
}

collect_guest_artifacts() {
    install -d -m 0700 "$WORK_DIR/artifacts"
    ssh_vm 20 \
        'sudo tar -czf "$HOME/zapret-sonar-vm/failure-artifacts.tar.gz" -C "$HOME/zapret-sonar-vm/artifacts" . && sudo chown "$USER" "$HOME/zapret-sonar-vm/failure-artifacts.tar.gz"' \
        2>/dev/null || return 0
    scp_vm 20 "$SSH_USER@127.0.0.1:zapret-sonar-vm/failure-artifacts.tar.gz" "$WORK_DIR/" 2>/dev/null || return 0
    tar -xzf "$WORK_DIR/failure-artifacts.tar.gz" -C "$WORK_DIR/artifacts"
}

load_profile() {
    local row
    PROFILE="$1"
    row=$(manifest_row "$IMAGE_MANIFEST" "$PROFILE") || die "unknown profile: $PROFILE"
    IFS=$'\t' read -r _ IMAGE_ID IMAGE_FILE IMAGE_URL IMAGE_CHECKSUM SSH_USER SSH_PORT <<< "$row"
}

setup_ssh() {
    SSH_OPTIONS=(
        -i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes
        -o ConnectTimeout=5 -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    )
    SCP_OPTIONS=(
        -i "$SSH_KEY" -P "$SSH_PORT" -o BatchMode=yes
        -o ConnectTimeout=5 -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    )
}

ssh_vm() {
    local seconds="$1"
    shift
    timeout --foreground --kill-after=5 "$seconds" ssh "${SSH_OPTIONS[@]}" "$SSH_USER@127.0.0.1" "$@"
}

scp_vm() {
    local seconds="$1"
    shift
    timeout --foreground --kill-after=5 "$seconds" scp "${SCP_OPTIONS[@]}" "$@"
}

start_vm() {
    local overlay="$1" nic
    nic="user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    qemu-system-x86_64 \
        -enable-kvm -cpu host -smp "$VM_CPUS" -m "$VM_MEMORY" \
        -drive "file=$overlay,format=qcow2,if=virtio" \
        -drive "file=$WORK_DIR/seed.img,format=raw,if=virtio,readonly=on" \
        -nic "$nic" \
        -display none -monitor none -serial "file:$WORK_DIR/serial.log" \
        >"$WORK_DIR/qemu.log" 2>&1 &
    QEMU_PID=$!
}

wait_for_qemu_exit() {
    local remaining=60 state
    while (( remaining > 0 )); do
        state=$(ps -o stat= -p "$QEMU_PID" 2>/dev/null || true)
        [[ -n "$state" && "$state" != Z* ]] || break
        sleep 1
        remaining=$((remaining - 1))
    done
    state=$(ps -o stat= -p "$QEMU_PID" 2>/dev/null || true)
    [[ -z "$state" || "$state" == Z* ]] || return 1
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
}

prepared_fingerprint() {
    {
        printf '%s\n' "$PREPARED_FORMAT_VERSION" "$IMAGE_ID" "$IMAGE_CHECKSUM"
        sha256sum "$SCRIPT_DIR/prepare-guest.sh"
    } | sha256sum | awk '{print $1}'
}

prepared_image_path() {
    printf '%s/%s.qcow2\n' "$PREPARED_DIR" "$IMAGE_ID"
}

prepared_image_valid() {
    local image stamp expected
    image=$(prepared_image_path)
    stamp="$image.fingerprint"
    expected=$(prepared_fingerprint)
    [[ -f "$image" && -f "$stamp" && "$(<"$stamp")" == "$expected" ]] || return 1
    qemu-img check -q "$image" >/dev/null 2>&1
}

prepare_image() {
    local source_image prepared_image fingerprint overlay log rc started
    load_profile "$1"
    source_image="$CACHE_DIR/$IMAGE_FILE"
    download_verified "$source_image" "$IMAGE_URL" "$IMAGE_CHECKSUM"
    prepared_image=$(prepared_image_path)
    fingerprint=$(prepared_fingerprint)
    if [[ "${2:-0}" != 1 ]] && prepared_image_valid; then
        printf 'Prepared image ready: %s\n' "$IMAGE_ID"
        return 0
    fi

    install -d -m 0755 "$PREPARED_DIR"
    WORK_DIR=$(mktemp -d "$PREPARED_DIR/.build-$IMAGE_ID.XXXXXX")
    install -d -m 0700 "$WORK_DIR/artifacts"
    make_seed
    setup_ssh
    overlay="$WORK_DIR/prepared.qcow2"
    qemu-img create -q -f qcow2 -F qcow2 -b "$source_image" "$overlay"
    qemu-img resize -q "$overlay" 8G
    printf 'Preparing image %s (one-time package provisioning)\n' "$IMAGE_ID"
    start_vm "$overlay"
    wait_for_ssh
    scp_vm 30 "$SCRIPT_DIR/prepare-guest.sh" "$SSH_USER@127.0.0.1:prepare-guest.sh"
    log="$WORK_DIR/provision.log"
    started=$SECONDS
    set +e
    timeout --foreground "$PROVISION_TIMEOUT" ssh "${SSH_OPTIONS[@]}" "$SSH_USER@127.0.0.1" \
        "sudo timeout --foreground --kill-after=10 $((PROVISION_TIMEOUT - 30)) bash '/home/$SSH_USER/prepare-guest.sh' '$IMAGE_ID'" >"$log" 2>&1
    rc=$?
    set -e
    if (( rc != 0 )); then
        printf 'Image preparation failed for %s (exit %d); final log lines:\n' "$IMAGE_ID" "$rc" >&2
        tail -n 80 "$log" >&2
        return "$rc"
    fi

    local boot_id
    boot_id=$(ssh_vm 8 'cat /proc/sys/kernel/random/boot_id')
    printf 'Rebooting prepared image %s for verification\n' "$IMAGE_ID"
    reboot_guest "$boot_id"
    printf 'Verifying prepared image %s\n' "$IMAGE_ID"
    ssh_vm 30 \
        'command -v jq nft iptables ip6tables ipset >/dev/null && sudo nft list tables >/dev/null'
    printf 'Sealing and powering off prepared image %s\n' "$IMAGE_ID"
    ssh_vm 30 \
        "sudo bash -c 'set -e; cloud-init clean --logs --machine-id; rm -f /home/$SSH_USER/.ssh/authorized_keys /etc/zapret-sonar-vm-nonce; test \"\$(cat /etc/machine-id)\" = uninitialized || test ! -s /etc/machine-id; test ! -e /etc/zapret-sonar-vm-nonce; test ! -e /var/lib/cloud/instance; sync'" \
        >/dev/null
    # The cleanup transaction above is the invariant. Use the common bounded
    # shutdown path rather than requiring every cloud image to exit QEMU itself.
    stop_vm
    qemu-img check -q "$overlay"
    mv -f "$overlay" "$prepared_image"
    printf '%s\n' "$fingerprint" > "$prepared_image.fingerprint.tmp"
    mv -f "$prepared_image.fingerprint.tmp" "$prepared_image.fingerprint"
    rm -rf -- "$WORK_DIR"
    WORK_DIR=""
    printf 'PASS: prepared image %s in %ds\n' "$IMAGE_ID" "$((SECONDS - started))"
}

run_profile() {
    load_profile "$1"
    local backing overlay started=$SECONDS
    backing=$(prepared_image_path)
    prepared_image_valid || die "prepared image is missing or stale: $IMAGE_ID"

    WORK_DIR=$(mktemp -d "/tmp/zapret-sonar-vm-$PROFILE.XXXXXX")
    install -d -m 0700 "$WORK_DIR/artifacts"
    make_source_archive
    make_seed
    overlay="$WORK_DIR/overlay.qcow2"
    qemu-img create -q -f qcow2 -F qcow2 -b "$backing" "$overlay"
    qemu-img resize -q "$overlay" 8G

    setup_ssh

    printf '\n=== %s ===\n' "$PROFILE"
    start_vm "$overlay"

    wait_for_ssh
    copy_guest_inputs
    if ! run_guest_phase; then
        return 1
    fi
    stop_vm
    rm -rf -- "$WORK_DIR"
    WORK_DIR=""
    printf 'PASS: %s in %ds\n' "$PROFILE" "$((SECONDS - started))"
}

probe_reboot() {
    load_profile "$1"
    local source_image overlay boot_id started
    source_image="$CACHE_DIR/$IMAGE_FILE"
    download_verified "$source_image" "$IMAGE_URL" "$IMAGE_CHECKSUM"
    started=$SECONDS
    WORK_DIR=$(mktemp -d "/tmp/zapret-sonar-vm-probe-$PROFILE.XXXXXX")
    install -d -m 0700 "$WORK_DIR/artifacts"
    make_seed
    setup_ssh
    overlay="$WORK_DIR/overlay.qcow2"
    qemu-img create -q -f qcow2 -F qcow2 -b "$source_image" "$overlay"
    printf 'Probing boot and reboot for %s\n' "$PROFILE"
    start_vm "$overlay"
    wait_for_ssh
    boot_id=$(ssh_vm 8 'cat /proc/sys/kernel/random/boot_id')
    reboot_guest "$boot_id"
    stop_vm
    rm -rf -- "$WORK_DIR"
    WORK_DIR=""
    printf 'PASS: reboot probe %s in %ds\n' "$PROFILE" "$((SECONDS - started))"
}

prepare_required_images() {
    local rebuild="$1"
    shift
    local seen=" " profile image_id
    for profile in "$@"; do
        load_profile "$profile"
        image_id="$IMAGE_ID"
        [[ "$seen" != *" $image_id "* ]] || continue
        prepare_image "$profile" "$rebuild"
        seen+="$image_id "
    done
}

run_profiles_parallel() {
    local jobs="$1"
    shift
    local profiles=("$@") index=0 slot pid rc failed profile log
    PARALLEL_DIR=$(mktemp -d /tmp/zapret-sonar-vm-parallel.XXXXXX)
    while (( index < ${#profiles[@]} )); do
        CHILD_PIDS=()
        local batch_profiles=() batch_logs=()
        for (( slot=0; slot<jobs && index<${#profiles[@]}; slot++, index++ )); do
            profile="${profiles[$index]}"
            log="$PARALLEL_DIR/$profile.log"
            ZF_VM_WORKER=1 bash "$0" "$profile" >"$log" 2>&1 &
            pid=$!
            CHILD_PIDS+=("$pid")
            batch_profiles+=("$profile")
            batch_logs+=("$log")
        done
        failed=0
        for (( slot=0; slot<${#CHILD_PIDS[@]}; slot++ )); do
            rc=0
            wait "${CHILD_PIDS[$slot]}" || rc=$?
            cat "${batch_logs[$slot]}"
            if (( rc != 0 )); then
                printf 'FAIL: %s (exit %d)\n' "${batch_profiles[$slot]}" "$rc" >&2
                failed=1
            fi
        done
        CHILD_PIDS=()
        (( failed == 0 )) || return 1
    done
    rm -rf -- "$PARALLEL_DIR"
    PARALLEL_DIR=""
}

usage() {
    printf 'Usage: %s [--jobs 1|2] [--prepare-images|--rebuild-images|--probe-reboot] [profile ...]\n' "$0"
    printf 'Profiles:\n'
    awk -F '\t' '$1 !~ /^#/ && NF { printf "  %s\n", $1 }' "$IMAGE_MANIFEST"
}

main() {
    require_commands
    validate_manifests
    if [[ "${ZF_VM_WORKER:-0}" == 1 ]]; then
        [[ $# == 1 ]] || die 'internal worker requires one profile'
        prepare_inputs
        run_profile "$1"
        return
    fi

    local jobs=1 prepare_only=0 rebuild=0 probe_only=0
    local profiles=()
    while (( $# > 0 )); do
        case "$1" in
            -h|--help) usage; return 0 ;;
            --jobs)
                (( $# >= 2 )) || die '--jobs requires 1 or 2'
                jobs="$2"
                shift 2
                ;;
            --prepare-images) prepare_only=1; shift ;;
            --rebuild-images) prepare_only=1; rebuild=1; shift ;;
            --probe-reboot) probe_only=1; shift ;;
            --*) die "unknown option: $1" ;;
            *) profiles+=("$1"); shift ;;
        esac
    done
    [[ "$jobs" == 1 || "$jobs" == 2 ]] || die '--jobs must be 1 or 2'
    (( ${#profiles[@]} > 0 )) || profiles=(ubuntu-nft arch-nft ubuntu-iptables-legacy fedora-nft)
    local profile
    for profile in "${profiles[@]}"; do
        manifest_row "$IMAGE_MANIFEST" "$profile" >/dev/null || die "unknown profile: $profile"
    done

    prepare_lock
    prepare_inputs
    if (( probe_only )); then
        for profile in "${profiles[@]}"; do probe_reboot "$profile"; done
        return 0
    fi
    prepare_required_images "$rebuild" "${profiles[@]}"
    (( prepare_only == 0 )) || { printf '\nPASS: prepared images are ready\n'; return 0; }
    local started
    started=$SECONDS
    if (( jobs == 1 )); then
        for profile in "${profiles[@]}"; do run_profile "$profile"; done
    else
        run_profiles_parallel "$jobs" "${profiles[@]}"
    fi
    printf '\nPASS: privileged VM matrix (%d profiles) in %ds\n' "${#profiles[@]}" "$((SECONDS - started))"
}

trap cleanup EXIT INT TERM
main "$@"
