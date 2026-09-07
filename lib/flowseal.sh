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

        if [[ -f "$old_lists/ipset-all.txt" ]]; then
            if [[ ! -s "$old_lists/ipset-all.txt" ]]; then
                : > "$ldir/ipset-all.txt"
                [[ -f "$src/lists/ipset-all.txt" ]] && install -m 644 "$src/lists/ipset-all.txt" "$ldir/ipset-all.txt.backup"
            elif tr -d '\r' < "$old_lists/ipset-all.txt" | grep -qxF '203.0.113.113/32'; then
                printf '203.0.113.113/32\n' > "$ldir/ipset-all.txt"
                [[ -f "$src/lists/ipset-all.txt" ]] && install -m 644 "$src/lists/ipset-all.txt" "$ldir/ipset-all.txt.backup"
            else
                install -m 644 "$old_lists/ipset-all.txt" "$ldir/ipset-all.txt"
                [[ -f "$old_lists/ipset-all.txt.backup" ]] && install -m 644 "$old_lists/ipset-all.txt.backup" "$ldir/ipset-all.txt.backup"
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
    ln -s ".flowseal-releases/$(basename "$release")" "$link_tmp" || return 1
    mv -Tf "$link_tmp" "$current" || { rm -f "$link_tmp"; return 1; }
}
