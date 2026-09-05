#!/usr/bin/env bash
# ============================================================================
# lib/zconfig.sh — генерация конфига zapret v1 из транслированной стратегии
#
# Состояние (какая стратегия применена, режимы фильтров) НЕ хранится в
# отдельном файле: оно записывается маркерами в сам конфиг zapret. Один
# источник истины, нечему разъезжаться.
#
# Конфиг zapret загружается через `.` (init.d/sysv/functions:6), то есть это
# исполняемый shell-код от root. Поэтому конфиг генерируется целиком нами и
# никогда не собирается из непроверенного пользовательского ввода.
# ============================================================================

[[ -n "${_ZF_ZCONFIG_SH:-}" ]] && return 0
_ZF_ZCONFIG_SH=1

ZF_ZAPRET_BASE="${ZF_ZAPRET_BASE:-/opt/zapret}"
ZF_ZAPRET_CONFIG="${ZF_ZAPRET_CONFIG:-$ZF_ZAPRET_BASE/config}"

ZF_MARK_STRATEGY="# zapret-sonar-strategy:"
ZF_MARK_GAMEFILTER="# zapret-sonar-gamefilter:"
ZF_MARK_IPSET="# zapret-sonar-ipset:"

# --- Чтение состояния --------------------------------------------------------
# zf_state KEY — печатает применённое значение (strategy|gamefilter|ipset)
# из маркеров конфига. Пусто, если конфиг не наш или отсутствует.
zf_state() {
    local key="$1" mark
    case "$key" in
        strategy)   mark="$ZF_MARK_STRATEGY" ;;
        gamefilter) mark="$ZF_MARK_GAMEFILTER" ;;
        ipset)      mark="$ZF_MARK_IPSET" ;;
        *) return 1 ;;
    esac
    [[ -r "$ZF_ZAPRET_CONFIG" ]] || return 0
    # Значение — весь остаток строки: имена стратегий содержат пробелы и скобки.
    sed -n "s|^${mark} ||p" "$ZF_ZAPRET_CONFIG" | head -1
}

# --- Генерация конфига -------------------------------------------------------
# zf_write_config STRATEGY_NAME GAMEFILTER IPSET_MODE
# Требует заранее заполненных ZF_OPT / ZF_PORTS_* (см. zf_translate).
#
# Запись атомарная: конфиг собирается в temp и подставляется через mv, чтобы
# systemctl restart никогда не прочитал полуготовый файл.
zf_write_config() {
    local strategy="$1" gamefilter="$2" ipset_mode="$3"

    [[ -n "$ZF_OPT" ]] || { printf 'zconfig: ZF_OPT пуст, сначала zf_translate\n' >&2; return 1; }

    # Первая наша запись — сохранить исходный конфиг zapret.
    if [[ -f "$ZF_ZAPRET_CONFIG" ]] && ! grep -q "^${ZF_MARK_STRATEGY}" "$ZF_ZAPRET_CONFIG"; then
        if [[ ! -f "$ZF_ZAPRET_CONFIG.orig" ]]; then
            cp -a "$ZF_ZAPRET_CONFIG" "$ZF_ZAPRET_CONFIG.orig" || return 1
            printf 'zconfig: исходный конфиг zapret сохранён в %s.orig\n' "$ZF_ZAPRET_CONFIG" >&2
        fi
    fi

    local tmp
    tmp=$(mktemp "${ZF_ZAPRET_CONFIG}.tmp.XXXXXX") || return 1

    {
        printf '# Сгенерировано zapret-sonar %s — правки будут перезаписаны.\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# Исходный конфиг zapret: %s.orig\n' "$ZF_ZAPRET_CONFIG"
        printf '%s %s\n' "$ZF_MARK_STRATEGY" "$strategy"
        printf '%s %s\n' "$ZF_MARK_GAMEFILTER" "$gamefilter"
        printf '%s %s\n' "$ZF_MARK_IPSET" "$ipset_mode"
        printf '\n'
        local fwtype="nftables"
    command -v nft >/dev/null 2>&1 || fwtype="iptables"
    printf 'FWTYPE=%s\n' "$fwtype"
        printf 'DISABLE_IPV6=1\n'
        # Без этого init.d/sysv/zapret:21 НЕ применяет правила firewall:
        # nfqws запускается, но трафик в его очередь не попадает. Проверять
        # обход в таком состоянии бессмысленно — он работать не будет
        # (либо заработает случайно, на чужих остаточных правилах).
        printf 'INIT_APPLY_FW=1\n'
        # Стратегии Flowseal несут свои --hostlist/--ipset в аргументах,
        # поэтому механизм подстановки <HOSTLIST> в zapret не используется.
        printf 'MODE_FILTER=none\n'
        printf 'FLOWOFFLOAD=none\n'
        printf 'TPWS_ENABLE=0\n'
        printf 'TPWS_SOCKS_ENABLE=0\n'
        printf 'NFQWS_ENABLE=1\n'
        printf 'NFQWS_PORTS_TCP=%s\n' "$ZF_PORTS_TCP"
        printf 'NFQWS_PORTS_UDP=%s\n' "$ZF_PORTS_UDP"
        # connbytes-лимиты: сколько первых пакетов соединения уходит в очередь.
        # Значения как в config.default zapret, экономят CPU.
        printf 'NFQWS_TCP_PKT_OUT=12\n'
        printf 'NFQWS_TCP_PKT_IN=3\n'
        printf 'NFQWS_UDP_PKT_OUT=12\n'
        printf 'NFQWS_UDP_PKT_IN=3\n'
        printf 'NFQWS_OPT="\n%s\n"\n' "$ZF_OPT"
    } > "$tmp" || { rm -f "$tmp"; return 1; }

    # Конфиг исполняется через `.` от root — синтаксическая ошибка означала бы
    # сломанный сервис. Проверяем до подстановки.
    if ! bash -n "$tmp" 2>/dev/null; then
        printf 'zconfig: сгенерирован невалидный shell-синтаксис, конфиг не заменён\n' >&2
        rm -f "$tmp"
        return 1
    fi

    if ! chmod 644 "$tmp" || ! mv -f "$tmp" "$ZF_ZAPRET_CONFIG"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# --- Режим ipset -------------------------------------------------------------
# Flowseal переключает ipset-all.txt тремя состояниями (service.bat:948-1013):
#   loaded — реальный список IP/подсетей;
#   none   — файл с единственной заглушкой 203.0.113.113/32 (ничего не матчит);
#   any    — пустой файл (nfqws трактует как «любой IP подходит»).
# Полный список хранится в ipset-all.txt.backup.
#
# Списки Flowseal приходят в CRLF. Для nfqws это безвредно — он сам режет
# \r при чтении (nfq/hostlist.c:12, nfq/ipset.c:19), поэтому файлы не
# конвертируются. Но сравнивать с заглушкой надо без учёта \r.
ZF_IPSET_STUB="203.0.113.113/32"

zf_ipset_mode() {
    local f="$1/ipset-all.txt"
    [[ -f "$f" ]] || { printf 'unknown\n'; return 0; }
    if [[ ! -s "$f" ]]; then
        printf 'any\n'
    elif tr -d '\r' < "$f" | grep -qxF "$ZF_IPSET_STUB"; then
        printf 'none\n'
    else
        printf 'loaded\n'
    fi
}

# zf_set_ipset_mode LISTS_DIR MODE
zf_set_ipset_mode() {
    local lists_dir="$1" mode="$2"
    local f="$lists_dir/ipset-all.txt" b="$lists_dir/ipset-all.txt.backup"
    local cur; cur=$(zf_ipset_mode "$lists_dir")
    [[ "$cur" == "$mode" ]] && return 0

    # Полный список нельзя потерять: перед уходом из loaded сохраняем его.
    if [[ "$cur" == "loaded" && ! -f "$b" ]]; then
        cp -a "$f" "$b" || return 1
    fi

    case "$mode" in
        none) printf '%s\n' "$ZF_IPSET_STUB" > "$f" ;;
        any)  : > "$f" ;;
        loaded)
            if [[ ! -f "$b" ]]; then
                printf 'zconfig: нет ipset-all.txt.backup — восстановить список нечем\n' >&2
                return 1
            fi
            cp -a "$b" "$f" || return 1 ;;
        *) printf 'zconfig: неизвестный режим ipset: %s\n' "$mode" >&2; return 1 ;;
    esac
    return 0
}
