#!/usr/bin/env bash

[[ -n "${_ZF_SELF_UPDATE_SH:-}" ]] && return 0
_ZF_SELF_UPDATE_SH=1

ZF_SELF_REPO="${ZF_SELF_REPO:-oxygen-syndata/zapret-sonar}"

zf_self_validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

zf_self_verify_checksum() {
    local sums="$1" archive="$2" asset="$3" expected count actual
    count=$(awk -v asset="$asset" '$2 == asset { count++ } END { print count+0 }' "$sums")
    [[ "$count" == 1 ]] || return 1
    expected=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$sums")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum "$archive" | cut -d' ' -f1)
    [[ "$actual" == "$expected" ]]
}

zf_self_validate_tree() {
    local tree="$1" expected="$2" version="" line key value seen=0 file
    [[ -f "$tree/RELEASE" && ! -L "$tree/RELEASE" ]] || return 1
    while IFS= read -r line; do
        key=${line%%=*}; value=${line#*=}
        case "$key" in
            format) [[ "$value" == 1 ]] || return 1 ;;
            version) version="$value"; seen=$((seen + 1)) ;;
            *) return 1 ;;
        esac
    done < "$tree/RELEASE"
    (( seen == 1 )) && [[ "$version" == "$expected" ]] || return 1
    for file in zapret-sonar zapret-sonar-tui lib/translate.sh lib/zconfig.sh lib/health.sh lib/flowseal.sh lib/self-update.sh; do
        [[ -f "$tree/$file" && ! -L "$tree/$file" ]] || return 1
        bash -n "$tree/$file" || return 1
    done
    grep -qx "ZF_VERSION=\"$expected\"" "$tree/zapret-sonar" || return 1
}

zf_self_validate_archive() {
    local archive="$1" version="$2" prefix member type
    prefix="zapret-sonar-v$version/"
    local -A seen=()
    while IFS=$'\t' read -r type member; do
        case "$member" in
            "$prefix"|"${prefix}lib/") [[ "$type" == d ]] || return 1 ;;
            "${prefix}RELEASE"|"${prefix}zapret-sonar"|"${prefix}zapret-sonar-tui"|"${prefix}lib/"*.sh)
                [[ "$type" == - ]] || return 1 ;;
            *) return 1 ;;
        esac
        [[ -z "${seen[$member]:-}" ]] || return 1
        seen[$member]=1
    done < <(tar -tvzf "$archive" | sed -E 's/^(.).* [^ ]+$/\1\t&/' | sed -E 's/^(.)(.*\t).* ([^ ]+)$/\1\t\3/')
    for member in RELEASE zapret-sonar zapret-sonar-tui lib/translate.sh lib/zconfig.sh lib/health.sh lib/flowseal.sh lib/self-update.sh; do
        [[ -n "${seen[${prefix}${member}]:-}" ]] || return 1
    done
}

zf_self_switch() {
    local install_root="$1" target="$2" tmp
    tmp="$install_root/.current.$$"
    [[ -d "$install_root/releases/$target" && ! -L "$install_root/releases/$target" ]] || return 1
    ln -s "releases/$target" "$tmp" || return 1
    mv -Tf "$tmp" "$install_root/current" || { rm -f "$tmp"; return 1; }
}

zf_self_prune() {
    local install_root="$1" current="$2" previous="${3:-}" release id
    for release in "$install_root/releases"/*; do
        [[ -d "$release" && ! -L "$release" ]] || continue
        id=$(basename "$release")
        [[ "$id" == "$current" || "$id" == "$previous" ]] && continue
        rm -rf -- "$release" || return 1
    done
}
