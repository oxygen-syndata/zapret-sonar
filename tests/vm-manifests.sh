#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_MANIFEST="$SCRIPT_DIR/vm/images.tsv"
UPSTREAM_MANIFEST="$SCRIPT_DIR/vm/upstream.tsv"
seen_profiles=" "
seen_ports=" "

seen_images=" "
while IFS=$'\t' read -r profile image_id file url checksum user port extra; do
    [[ -n "$profile" && "$profile" != \#* ]] || continue
    [[ -z "${extra:-}" && -n "$image_id" && -n "$file" && -n "$url" && -n "$user" ]] || exit 1
    [[ "$checksum" =~ ^[0-9a-f]{64}$ && "$port" =~ ^[0-9]+$ ]] || exit 1
    [[ "$profile" =~ ^[a-z0-9][a-z0-9-]*$ && "$image_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 1
    [[ "$file" == "${file##*/}" && "$file" != . && "$file" != .. && "$url" == https://* ]] || exit 1
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ && "$port" -ge 1024 && "$port" -le 65535 ]] || exit 1
    [[ "$seen_profiles" != *" $profile "* && "$seen_ports" != *" $port "* ]] || exit 1
    seen_profiles+="$profile "
    seen_ports+="$port "
    if [[ "$seen_images" != *" $image_id "* ]]; then
        grep -Fq "${image_id%%-*}-" "$SCRIPT_DIR/vm/prepare-guest.sh" || exit 1
        seen_images+="$image_id "
    fi
done < "$IMAGE_MANIFEST"

count=0
seen_names=" "
seen_files=" "
while IFS=$'\t' read -r name file url checksum extra; do
    [[ -n "$name" && "$name" != \#* ]] || continue
    [[ -z "${extra:-}" && -n "$file" && "$checksum" =~ ^[0-9a-f]{64}$ ]] || exit 1
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ && "$file" == "${file##*/}" && "$file" != . && "$file" != .. ]] || exit 1
    [[ "$url" == https://* && "$seen_names" != *" $name "* && "$seen_files" != *" $file "* ]] || exit 1
    seen_names+="$name "
    seen_files+="$file "
    count=$((count + 1))
done < "$UPSTREAM_MANIFEST"

[[ "$count" == 3 ]] || exit 1
printf 'PASS: VM manifests and curl fixture are consistent\n'
