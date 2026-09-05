#!/usr/bin/env bash
# ============================================================================
# lib/translate.sh — трансляция стратегий Flowseal (.bat) в конфиг zapret v1
#
# Стратегии Flowseal написаны для winws.exe (Windows/WinDivert). nfqws на
# Linux говорит на том же диалекте опций (проверено: все 32 опции из 22
# стратегий присутствуют в nfqws v72.13), кроме двух отличий:
#
#   1. --wf-tcp / --wf-udp — опции WinDivert, nfqws их не знает. На Linux
#      их роль выполняет firewall, поэтому порты извлекаются отдельно
#      в NFQWS_PORTS_TCP / NFQWS_PORTS_UDP.
#   2. Пути в .bat закавычены ("%LISTS%list.txt"). Внутри NFQWS_OPT="..."
#      кавычки надо снять, иначе они попадут в имя файла как символы.
# ============================================================================

[[ -n "${_ZF_TRANSLATE_SH:-}" ]] && return 0
_ZF_TRANSLATE_SH=1

# Порты для %GameFilter*% когда фильтр выключен.
# Порт 12 практически не встречается в реальном трафике, но сохраняет
# группу --filter-tcp=12 синтаксически валидной. Пустая подстановка сделала
# бы аргументы "осиротевшими" и они применились бы ко всему трафику.
ZF_GAMEFILTER_OFF="12"
ZF_GAMEFILTER_ON="1024-65535"

# --- Результат трансляции (глобальные, читаются вызывающим) ------------------
ZF_PORTS_TCP=""
ZF_PORTS_UDP=""
ZF_OPT=""

# ---------------------------------------------------------------------------
# zf_translate BAT_FILE BIN_DIR LISTS_DIR [GAME_FILTER]
#
# GAME_FILTER: off (по умолчанию) | tcp | udp | both
# Заполняет ZF_PORTS_TCP, ZF_PORTS_UDP, ZF_OPT. Возвращает 1 при ошибке.
# ---------------------------------------------------------------------------
zf_translate() {
    local bat="$1" bin_dir="$2" lists_dir="$3" game_filter="${4:-off}"

    ZF_PORTS_TCP="" ZF_PORTS_UDP="" ZF_OPT=""

    [[ -f "$bat" ]] || { printf 'translate: файл не найден: %s\n' "$bat" >&2; return 1; }

    # Пробелы в путях сломали бы NFQWS_OPT: zapret передаёт его в nfqws без
    # кавычек (init.d/sysv/functions:175 — "$2" $3), поэтому путь с пробелом
    # распался бы на несколько аргументов. Проверяем заранее.
    local d
    for d in "$bin_dir" "$lists_dir"; do
        case "$d" in
            *[[:space:]]*)
                printf 'translate: путь содержит пробел, nfqws это не переживёт: %s\n' "$d" >&2
                return 1 ;;
        esac
    done

    local gf_tcp="$ZF_GAMEFILTER_OFF" gf_udp="$ZF_GAMEFILTER_OFF"
    case "$game_filter" in
        both) gf_tcp="$ZF_GAMEFILTER_ON"; gf_udp="$ZF_GAMEFILTER_ON" ;;
        tcp)  gf_tcp="$ZF_GAMEFILTER_ON" ;;
        udp)  gf_udp="$ZF_GAMEFILTER_ON" ;;
        off)  ;;
        *) printf 'translate: неизвестный game_filter: %s\n' "$game_filter" >&2; return 1 ;;
    esac

    local c
    # CRLF → LF, затем берём только строку запуска winws.exe и всё, что
    # к ней подклеено через ^ (продолжение строки в cmd).
    c=$(tr -d '\r' < "$bat" | sed -n '/winws\.exe/,$p')
    [[ -n "$c" ]] || { printf 'translate: не найден вызов winws.exe в %s\n' "$bat" >&2; return 1; }

    # ^! — это экранированный "!" в cmd (delayed expansion), а не продолжение
    # строки. Снимаем ДО обработки продолжений, иначе "^" останется в
    # аргументе и nfqws упадёт с "could not read ^!".
    c="${c//^!/!}"

    # Склейка продолжений строк: "^" в конце строки + перевод строки → пробел.
    c=$(printf '%s\n' "$c" | sed -E ':a; s/\^[[:space:]]*$//; ta' | tr '\n' ' ')

    # Отрезаем всё до самого winws.exe (включая путь и закрывающую кавычку).
    c="${c#*winws.exe\"}"
    c="${c#*winws.exe}"

    # Подстановка переменных окружения .bat. В оригинале %BIN% и %LISTS%
    # заканчиваются на "\", здесь добавляем "/" вместо него.
    c="${c//%BIN%/$bin_dir/}"
    c="${c//%LISTS%/$lists_dir/}"
    c="${c//%GameFilterTCP%/$gf_tcp}"
    c="${c//%GameFilterUDP%/$gf_udp}"
    c="${c//%GameFilter%/$gf_tcp}"

    # --wf-tcp/--wf-udp → порты для firewall (см. заголовок файла).
    ZF_PORTS_TCP=$(printf '%s' "$c" | grep -oE -- '--wf-tcp=[0-9,-]+' | head -1)
    ZF_PORTS_UDP=$(printf '%s' "$c" | grep -oE -- '--wf-udp=[0-9,-]+' | head -1)
    ZF_PORTS_TCP="${ZF_PORTS_TCP#--wf-tcp=}"
    ZF_PORTS_UDP="${ZF_PORTS_UDP#--wf-udp=}"
    c=$(printf '%s' "$c" | sed -E 's/--wf-(tcp|udp)=[0-9,-]*//g')

    # Чистка после подстановки плейсхолдеров: схлопнуть повторные запятые,
    # убрать висячие перед пробелом/--/концом строки, выбросить опустевшие
    # --filter-tcp= / --filter-udp=.
    c=$(printf '%s' "$c" | sed -E \
        -e 's/,+/,/g' \
        -e 's/,( |--)/\1/g' \
        -e 's/,$//' \
        -e 's/--filter-tcp=( |$)/\1/g' \
        -e 's/--filter-udp=( |$)/\1/g')

    # Снятие кавычек с путей (см. п.2 в заголовке).
    c="${c//\"/}"

    # Нормализация пробелов.
    c=$(printf '%s' "$c" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

    ZF_PORTS_TCP="${ZF_PORTS_TCP#,}"; ZF_PORTS_TCP="${ZF_PORTS_TCP%,}"
    ZF_PORTS_UDP="${ZF_PORTS_UDP#,}"; ZF_PORTS_UDP="${ZF_PORTS_UDP%,}"

    if [[ -z "$ZF_PORTS_TCP" && -z "$ZF_PORTS_UDP" ]]; then
        printf 'translate: не найдено --wf-tcp/--wf-udp в %s\n' "$bat" >&2
        return 1
    fi
    [[ -n "$c" ]] || { printf 'translate: пустой результат для %s\n' "$bat" >&2; return 1; }

    # Санитизация: конфиг zapret исполняется через `.` от root, поэтому
    # результат трансляции не должен содержать shell-метасимволы. Ни одна
    # легальная стратегия Flowseal их не использует (проверено на всех 22).
    # Без этой проверки компрометация релиза Flowseal → root RCE.
    # *'\'* — одиночный backslash (в одинарных кавычках \\ = два литерала).
    if [[ "$c" == *'$'* || "$c" == *'`'* || "$c" == *'\'* || "$c" == *'"'* || \
          "$c" == *';'* || "$c" == *'&'* || "$c" == *'|'* || "$c" == *'<'* || \
          "$c" == *'>'* || "$c" == *'('* || "$c" == *')'* ]]; then
        printf 'translate: стратегия содержит shell-метасимволы, отклонено: %s\n' "$bat" >&2
        return 1
    fi

    ZF_OPT="$c"
    return 0
}

# ---------------------------------------------------------------------------
# zf_referenced_files — файлы, на которые ссылается результат трансляции.
# Печатает по одному пути на строку. Нужно для проверки, что все hostlist
# и .bin на месте: nfqws падает при отсутствующем файле.
#
# Исключаются значения, которые НЕ являются путями:
#   --dpi-desync-fake-tls-mod=rnd,dupsid,sni=...  — список модификаторов;
#   --dpi-desync-fake-tls=0x00000000              — inline hex-блоб;
#   --dpi-desync-fake-tls=!  или  !+N             — встроенный блоб nfqws
#                                                   (nfq/nfqws.c:3024).
# ---------------------------------------------------------------------------
zf_referenced_files() {
    printf '%s' "$ZF_OPT" \
        | grep -oE -- '--(hostlist|hostlist-exclude|ipset|ipset-exclude|dpi-desync-fake-[a-z-]+|dpi-desync-split-seqovl-pattern|dpi-desync-fakedsplit-pattern)=[^ ]+' \
        | grep -v -- '-mod=' \
        | sed -E 's/^[^=]+=//' \
        | grep -vE '^(0x[0-9a-fA-F]*|!\+?[0-9]*|)$' \
        | sort -u
}

# ---------------------------------------------------------------------------
# zf_verify NFQWS_BIN — проверить результат самим nfqws (--dry-run).
# Это авторитетная проверка: nfqws разбирает аргументы своим парсером
# и выходит с кодом 0, ничего не запуская и не трогая сеть.
# ---------------------------------------------------------------------------
zf_verify() {
    local nfqws="$1" out rc
    [[ -x "$nfqws" ]] || { printf 'verify: нет бинарника %s\n' "$nfqws" >&2; return 1; }
    # ZF_OPT намеренно без кавычек — нужно разбиение на аргументы.
    # shellcheck disable=SC2086
    out=$("$nfqws" --dry-run --qnum=200 $ZF_OPT 2>&1); rc=$?
    if (( rc != 0 )); then
        printf '%s\n' "$out" | tail -3 >&2
        return 1
    fi
    return 0
}
