#!/usr/bin/env bash

[[ -n "${_ZF_FLOWSEAL_SH:-}" ]] && return 0
_ZF_FLOWSEAL_SH=1

zf_prepare_flowseal_tree() {
    local src="$1" dest="$2" old_lists="${3:-}"
    local sdir="$dest/strategies" bdir="$dest/bin" ldir="$dest/lists"
    local file name count=0

    [[ -d "$src/bin" && -d "$src/lists" ]] || return 1
    mkdir -p "$sdir" "$bdir" "$ldir" || return 1

    for file in "$src"/*.bat; do
        [[ -f "$file" ]] || continue
        name=$(basename "$file")
        [[ "$name" =~ ^(service|service_remove|install_service)\.bat$ ]] && continue
        install -m 644 "$file" "$sdir/" || return 1
        count=$((count + 1))
    done
    (( count > 0 )) || return 1

    for file in "$src/bin"/*.bin; do
        [[ -f "$file" ]] || continue
        install -m 644 "$file" "$bdir/" || return 1
    done
    find "$bdir" -maxdepth 1 -name '*.bin' -print -quit | grep -q . || return 1

    for file in "$src/lists"/*; do
        [[ -f "$file" ]] || continue
        install -m 644 "$file" "$ldir/" || return 1
    done

    if [[ -d "$old_lists" ]]; then
        for file in "$old_lists"/*-user.txt; do
            [[ -f "$file" ]] || continue
            install -m 644 "$file" "$ldir/" || return 1
        done

        if [[ -f "$old_lists/ipset-all.txt" && -f "$src/lists/ipset-all.txt" ]]; then
            if [[ ! -s "$old_lists/ipset-all.txt" ]]; then
                : > "$ldir/ipset-all.txt"
                install -m 644 "$src/lists/ipset-all.txt" "$ldir/ipset-all.txt.backup"
            elif tr -d '\r' < "$old_lists/ipset-all.txt" | grep -qxF '203.0.113.113/32'; then
                printf '203.0.113.113/32\n' > "$ldir/ipset-all.txt"
                install -m 644 "$src/lists/ipset-all.txt" "$ldir/ipset-all.txt.backup"
            else
                install -m 644 "$src/lists/ipset-all.txt" "$ldir/ipset-all.txt"
                install -m 644 "$src/lists/ipset-all.txt" "$ldir/ipset-all.txt.backup"
            fi
        fi
    fi

    for name in list-general-user.txt list-exclude-user.txt ipset-exclude-user.txt; do
        [[ -f "$ldir/$name" ]] || : > "$ldir/$name"
        chmod 644 "$ldir/$name" || return 1
    done
}

zf_activate_flowseal_tree() {
    local stage="$1" release="$2" current="$3"
    local link_tmp="${current}.tmp.$$"

    mkdir -p "$(dirname "$release")" || return 1
    mv "$stage" "$release" || return 1
    if ! ln -s ".flowseal-releases/$(basename "$release")" "$link_tmp"; then
        mv "$release" "$stage" 2>/dev/null || true
        return 1
    fi
    if ! mv -Tf "$link_tmp" "$current"; then
        rm -f "$link_tmp"
        mv "$release" "$stage" 2>/dev/null || true
        return 1
    fi
}

zf_restore_flowseal_tree() {
    local current="$1" target="$2"
    local link_tmp="${current}.restore.$$"

    [[ -n "$target" ]] || return 1
    ln -s "$target" "$link_tmp" || return 1
    mv -Tf "$link_tmp" "$current" || { rm -f "$link_tmp"; return 1; }
}

zf_remove_flowseal_release() {
    local releases="$1" release="$2"
    [[ -n "$release" && -d "$release" && ! -L "$release" ]] || return 1
    [[ "$(dirname "$release")" == "$releases" ]] || return 1
    rm -rf -- "$release"
}

zf_prune_flowseal_releases() {
    local releases="$1" current="$2" previous="${3:-}"
    local release base

    [[ -d "$releases" && ! -L "$releases" ]] || return 1
    current=$(basename "$current")
    [[ -n "$previous" ]] && previous=$(basename "$previous")

    for release in "$releases"/*; do
        [[ -d "$release" && ! -L "$release" ]] || continue
        base=$(basename "$release")
        [[ "$base" == "$current" || "$base" == "$previous" ]] && continue
        zf_remove_flowseal_release "$releases" "$release" || return 1
    done
}

zf_flowseal_release_id() {
    local release="$1" releases="$2" id
    [[ -d "$release" && ! -L "$release" && "$(dirname "$release")" == "$releases" ]] || return 1
    id=$(basename "$release")
    [[ -n "$id" && "$id" != . && "$id" != .. && "$id" != */* ]] || return 1
    printf '%s\n' "$id"
}

zf_write_flowseal_metadata() {
    local release="$1" releases="$2" version="$3" created_at="${4:-}"
    zf_flowseal_release_id "$release" "$releases" >/dev/null || return 1
    [[ "$version" == main || "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
    [[ -n "$created_at" ]] || created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local tmp
    tmp=$(mktemp "$release/.flowseal-release.XXXXXX") || return 1
    printf 'format=1\nflowseal_version=%s\ncreated_at=%s\n' "$version" "$created_at" > "$tmp" \
        && chmod 644 "$tmp" && mv -f "$tmp" "$release/.flowseal-release" \
        || { rm -f "$tmp"; return 1; }
}

zf_read_flowseal_metadata() {
    local release="$1" key="$2" file line name value result="" seen=0
    file="$release/.flowseal-release"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    while IFS= read -r line; do
        name=${line%%=*}; value=${line#*=}
        case "$name" in format|flowseal_version|created_at) ;; *) return 1 ;; esac
        if [[ "$name" == "$key" ]]; then result="$value"; seen=$((seen + 1)); fi
    done < "$file"
    (( seen == 1 )) || return 1
    printf '%s\n' "$result"
}
