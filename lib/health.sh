#!/usr/bin/env bash
# ============================================================================
# lib/health.sh — проверка, работает ли обход
#
# Двухуровневая проверка, потому что HTTP-кода недостаточно:
#
#   1. HTTP-код — быстро, но ТСПУ умеет отдавать 200 с заглушкой или рвать
#      соединение на середине ответа.
#   2. Медиа-проверка — скачивается кусочек реального файла с CDN и
#      сверяются объём и magic bytes. Ловит throttling и подмену контента,
#      которые по коду 200 неотличимы от нормы.
#
# Проверка ничего не переключает и не пишет в конфиг: это индикатор для
# пользователя, а не автопилот. Решение о смене стратегии принимает человек.
# ============================================================================

[[ -n "${_ZF_HEALTH_SH:-}" ]] && return 0
_ZF_HEALTH_SH=1

ZF_HEALTH_TIMEOUT="${ZF_HEALTH_TIMEOUT:-8}"

# Цели HTTP-проверки: "URL"
# Проверяем все ключевые точки: web, api, gateway для Discord и google/youtube
ZF_HEALTH_HOSTS=(
    "https://www.youtube.com"
    "https://discord.com"
    "https://gateway.discord.gg"
    "https://discord.com/api/v9/experiments"
)

# Отдельный набор для проверки конкретной стратегии: только те цели, что
# действительно блокируются. Смысл в том, что незаблокированный ресурс
# отвечает 200 и без обхода, поэтому по нему нельзя судить о стратегии.
ZF_HEALTH_TARGETS_STRICT=(
    "https://discord.com"
    "https://gateway.discord.gg"
    "https://discord.com/api/v9/experiments"
    "https://cdn.discordapp.com/embed/avatars/0.png"
)

# Цели контроля регрессии: ресурсы, которые работают и БЕЗ обхода. Неудачная
# стратегия способна их сломать (замерено: ALT2 роняет youtube.com в 000,
# при этом снимая блокировку Discord). Стратегия, открывшая заблокированное
# но убившая работавшее, — не рабочая.
ZF_HEALTH_TARGETS_CONTROL=(
    "https://www.youtube.com"
    "https://www.google.com"
    "https://yt3.ggpht.com/a/default-user=s88-c-k-c0x00ffffff-no-rj"
)

# Заполняется zf_baseline: какие цели заблокированы, а какие работали до
# включения обхода. Перебор стратегий опирается на этот замер.
ZF_BASELINE_BLOCKED=()
ZF_BASELINE_WORKING=()

# Цели медиа-проверки: "URL|min_bytes|magic_hex|min_speed_kb"
# 1. Аватарка Google / YT (проверка целостности и сигнатуры JPEG)
# 2. Аватарка Discord CDN (проверка целостности и сигнатуры PNG)
# 3. Реальный бинарный блок Discord CDN (512 КБ с замером скорости для отсечения throttling)
ZF_HEALTH_MEDIA=(
    "https://yt3.ggpht.com/a/default-user=s88-c-k-c0x00ffffff-no-rj|1000|ffd8ff|0"
    "https://cdn.discordapp.com/embed/avatars/0.png|500|89504e47|0"
    "https://dl.discordapp.net/apps/linux/0.0.60/discord-0.0.60.tar.gz|200000||200"
)

# --- Хекс первых N байт файла ------------------------------------------------
# xxd есть не везде; od — часть coreutils и есть всегда. В fallback критично
# удалять и пробелы, и переводы строк: od выводит "ff d8 ff".
_zf_head_hex() {
    local file="$1" nbytes="$2"
    if command -v xxd >/dev/null 2>&1; then
        xxd -p -l "$nbytes" "$file" 2>/dev/null | tr -d '\n'
    else
        od -An -tx1 -N "$nbytes" "$file" 2>/dev/null | tr -d ' \n'
    fi
}

# --- Общий критерий «код = успех» ---------------------------------------------
# Единый источник правды для baseline и scoring: 404 для gateway.discord.gg —
# нормальный ответ эндпоинта, 204 — No Content (некоторые API). Без этой
# функции baseline и scoring расходились: gateway помечался как «заблокирован»
# в baseline (404 не матчило 200|301|…), но «исправлен» в scoring (где 404
# принят), раздувая счётчик fixed.
_zf_code_ok() {
    local url="$1" code="$2"
    [[ "$url" =~ gateway\.discord\.gg && "$code" == "404" ]] && return 0
    [[ "$code" =~ ^(200|204|301|302|303|307|308)$ ]]
}

# --- HTTP-проверка -----------------------------------------------------------
# zf_check_host URL → 0 = доступен. Печатает строку отчёта.
# Ожидаются только валидные коды: 404 для gateway.discord.gg это норма (эндпоинт отвечает),
# для остальных — 200|204|301|302|303|307|308.
zf_check_host() {
    local url="$1" code
    code=$(LC_ALL=C curl -o /dev/null -s -m "$ZF_HEALTH_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
    if _zf_code_ok "$url" "$code"; then
        printf '  OK    %-42s HTTP %s\n' "$url" "$code"
        return 0
    fi
    if [[ "$code" == "000" ]]; then
        printf '  FAIL  %-42s нет соединения (таймаут/обрыв)\n' "$url"
    else
        printf '  FAIL  %-42s HTTP %s\n' "$url" "$code"
    fi
    return 1
}

# --- Медиа-проверка и замер скорости ------------------------------------------
# zf_check_media "URL|min_bytes|magic_hex|min_speed_kb" → 0 = контент настоящий и скорость в норме.
zf_check_media() {
    local spec="$1"
    local url="${spec%%|*}" rest="${spec#*|}"
    local min_bytes="${rest%%|*}" rest2="${rest#*|}"
    local magic="${rest2%%|*}" min_speed_kb="${rest2#*|}"
    [[ "$min_speed_kb" == "$magic" ]] && min_speed_kb="0"
    local tmp size speed_bps speed_kb actual rc=0

    tmp=$(mktemp) || return 1
    # Если указан min_speed_kb > 0, тянем порцию до 512 КБ для надёжного замера скорости.
    # Если min_speed_kb == 0, качаем файл целиком (для проверки сигнатур аватарок).
    local range_opt=()
    (( min_speed_kb > 0 )) && range_opt=(-r "0-$((min_bytes * 2))")

    local curl_out
    curl_out=$(LC_ALL=C curl -s -m "$ZF_HEALTH_TIMEOUT" "${range_opt[@]}" -w '%{http_code}|%{speed_download}' -o "$tmp" "$url" 2>/dev/null) || curl_out="000|0"
    local http_code="${curl_out%%|*}"
    speed_bps="${curl_out##*|}"
    speed_kb=$(( ${speed_bps%%[.,]*} / 1024 ))

    # 404/410 на медиа-цели — не сбой обхода, а устаревший URL (версия снята с CDN).
    if [[ "$http_code" =~ ^(404|410|451)$ ]]; then
        printf '  SKIP  %-42s HTTP %s — цель устарела\n' "$url" "$http_code"
        rm -f "$tmp"
        return 0
    fi
    if ! [[ "$http_code" =~ ^(200|206)$ ]]; then
        printf '  FAIL  %-42s HTTP %s (нет соединения)\n' "$url" "$http_code"
        rm -f "$tmp"
        return 1
    fi

    size=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    if (( size < min_bytes )); then
        printf '  FAIL  %-42s %s байт (ждали ≥%s) — обрыв\n' "$url" "$size" "$min_bytes"
        rm -f "$tmp"
        return 1
    fi

    if (( min_speed_kb > 0 && speed_kb < min_speed_kb )); then
        printf '  FAIL  %-42s скорость %s КБ/с (минимум %s КБ/с) — throttling\n' \
            "$url" "$speed_kb" "$min_speed_kb"
        rm -f "$tmp"
        return 1
    fi

    if [[ -n "$magic" ]]; then
        actual=$(_zf_head_hex "$tmp" "$(( ${#magic} / 2 ))")
        if [[ -z "$actual" ]]; then
            printf '  WARN  %-42s %s байт, сигнатуру проверить нечем\n' "$url" "$size"
            rm -f "$tmp"
            return 0
        fi
        if [[ "${actual,,}" != "${magic,,}" ]]; then
            printf '  FAIL  %-42s %s байт, сигнатура %s ≠ %s — подмена\n' \
                "$url" "$size" "$actual" "$magic"
            rm -f "$tmp"
            return 1
        fi
    fi

    if (( min_speed_kb > 0 )); then
        printf '  OK    %-42s %s байт (%s КБ/с, тест скорости пройден)\n' "$url" "$size" "$speed_kb"
    else
        printf '  OK    %-42s %s байт, сигнатура совпала\n' "$url" "$size"
    fi
    rm -f "$tmp"
    return $rc
}

# --- Полная проверка ---------------------------------------------------------
# zf_health_check → 0 если всё прошло. Печатает отчёт.
zf_health_check() {
    local failed=0 total=0 url spec

    printf 'HTTP-доступность:\n'
    for url in "${ZF_HEALTH_HOSTS[@]}"; do
        total=$((total + 1))
        zf_check_host "$url" || failed=$((failed + 1))
    done

    printf 'Целостность контента:\n'
    for spec in "${ZF_HEALTH_MEDIA[@]}"; do
        total=$((total + 1))
        zf_check_media "$spec" || failed=$((failed + 1))
    done

    printf '\nИтог: %d из %d проверок пройдено\n' "$((total - failed))" "$total"
    (( failed == 0 ))
}

# --- Базовая линия -----------------------------------------------------------
# zf_baseline — замер состояния БЕЗ обхода. Вызывать при остановленном сервисе.
#
# Замеряется два набора:
#   • цели из ZF_HEALTH_TARGETS_STRICT — что заблокировано (по ним судим,
#     сработала ли стратегия);
#   • цели из ZF_HEALTH_TARGETS_CONTROL — что работало до обхода (по ним
#     ловим регрессию: стратегия не должна ломать доступное).
#
# Результат складывается в ZF_BASELINE_BLOCKED / ZF_BASELINE_WORKING.
zf_baseline() {
    local url code
    ZF_BASELINE_BLOCKED=()
    ZF_BASELINE_WORKING=()

    # Заголовок не утверждает, что обход выключен: функция вызывается и при
    # активном сервисе (тогда вызывающий печатает предупреждение выше).
    printf 'Замер целей:\n'
    for url in "${ZF_HEALTH_TARGETS_STRICT[@]}" "${ZF_HEALTH_TARGETS_CONTROL[@]}"; do
        code=$(LC_ALL=C curl -o /dev/null -s -m "$ZF_HEALTH_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
        if _zf_code_ok "$url" "$code"; then
            printf '  доступен             %-42s HTTP %s\n' "$url" "$code"
            ZF_BASELINE_WORKING+=("$url")
        else
            printf '  ЗАБЛОКИРОВАН         %-42s %s\n' "$url" "$code"
            ZF_BASELINE_BLOCKED+=("$url")
        fi
    done

    if (( ${#ZF_BASELINE_BLOCKED[@]} == 0 )); then
        printf '\nНи одна цель не блокируется — проверить эффективность стратегий нечем.\n'
        return 1
    fi
    printf '\nЗаблокировано: %d (проверяем обход) | работает: %d (проверяем регрессию)\n' \
        "${#ZF_BASELINE_BLOCKED[@]}" "${#ZF_BASELINE_WORKING[@]}"
    return 0
}

# --- Оценка стратегии относительно базовой линии ------------------------------
# zf_score_strategy — печатает вердикт и возвращает:
#   0 — обход работает и ничего не сломано;
#   1 — обход не работает;
#   2 — обход работает, но сломаны ранее доступные ресурсы (регрессия).
#
# Третий случай выделен отдельно, потому что он самый коварный: проверка
# «только по заблокированным целям» показала бы успех. Замерено на ALT2:
# Discord открывается, а youtube.com перестаёт отвечать вовсе.
zf_score_strategy() {
    local url code fixed=0 still=0 broke=0
    local -a broken=()

    for url in "${ZF_BASELINE_BLOCKED[@]}"; do
        code=$(LC_ALL=C curl -o /dev/null -s -m "$ZF_HEALTH_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
        if _zf_code_ok "$url" "$code"; then
            fixed=$((fixed + 1))
        else
            still=$((still + 1))
        fi
    done

    for url in "${ZF_BASELINE_WORKING[@]}"; do
        code=$(LC_ALL=C curl -o /dev/null -s -m "$ZF_HEALTH_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
        if ! _zf_code_ok "$url" "$code"; then
            broke=$((broke + 1)); broken+=("$url")
        fi
    done

    if (( broke > 0 )); then
        printf 'СЛОМАЛА %d/%d (обход %d/%d) — %s' \
            "$broke" "${#ZF_BASELINE_WORKING[@]}" "$fixed" "${#ZF_BASELINE_BLOCKED[@]}" "${broken[0]}"
        (( ${#broken[@]} > 1 )) && printf ' и ещё %d' "$(( ${#broken[@]} - 1 ))"
        printf '\n'
        return 2
    fi
    if (( still == 0 )); then
        printf 'РАБОТАЕТ (%d/%d, регрессий нет)\n' "$fixed" "${#ZF_BASELINE_BLOCKED[@]}"
        return 0
    fi
    printf 'не работает (%d/%d)\n' "$fixed" "${#ZF_BASELINE_BLOCKED[@]}"
    return 1
}

# --- Предполётная проверка окружения -----------------------------------------
# Диагностика того, что искажает результаты проверок. Ничего не исправляет,
# только сообщает: причины могут быть намеренными (рабочий VPN, обход на
# роутере), и решать должен пользователь.
zf_preflight() {
    local warn=0

    # Открытый DNS — первое требование инструкции Flowseal. Без DoH/DoT
    # провайдер видит и может подменять запросы, и тогда любая стратегия
    # даёт недостоверный результат.
    if command -v resolvectl >/dev/null 2>&1; then
        local dns_status
        dns_status=$(resolvectl status 2>/dev/null)
        if [[ -n "$dns_status" ]] && ! printf '%s' "$dns_status" | grep -qE '\+DNSOverTLS|DNSOverTLS: yes'; then
            printf '  WARN  DNS без шифрования (нет DoT/DoH)\n'
            printf '        Flowseal требует Secure DNS: без него стратегии врут.\n'
            warn=$((warn + 1))
        fi
    fi

    # IPv6: конфиг задаёт DISABLE_IPV6=1, поэтому трафик по IPv6 идёт мимо
    # nfqws. Если у провайдера рабочий IPv6, YouTube/Google ходят по v6 —
    # обход не нужен и проверки дадут ложный результат.
    local v6addr
    v6addr=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6 || true)
    if (( v6addr > 0 )) && ip -6 route show default 2>/dev/null | grep -q .; then
        printf '  WARN  активен IPv6 (DISABLE_IPV6=1 в конфиге)\n'
        printf '        Трафик по IPv6 идёт мимо nfqws — проверки могут быть недостоверны.\n'
        warn=$((warn + 1))
    fi

    # Туннели: трафик может идти через VPN-туннель мимо nfqws, и тогда
    # «работает» ничего не доказывает. Исключаем только PPPoE-линки (ppp*)
    # — это WAN, а не туннель. Настоящие туннели (tun*/wg*/awg*) флагуем
    # ВСЕГДА, даже если они default route — full-tunnel VPN это главный кейс.
    local tun
    tun=$(ip -brief link show 2>/dev/null \
        | awk '$1 ~ /^(tun|wg|awg)/ && $0 ~ /UP/ {print $1}' \
        | paste -sd' ')
    if [[ -n "$tun" ]]; then
        printf '  WARN  активны туннели: %s\n' "$tun"
        printf '        Трафик может идти мимо nfqws — проверки недостоверны.\n'
        warn=$((warn + 1))
    fi

    # Конкурирующие обходы: два nfqws на одной очереди NFQUEUE конфликтуют.
    # Проверяем известные имена: zapret2 (Lua-форк) и zapret (оригинал bol-van,
    # если установлен штатно без нашей обёртки). Имя нашего сервиса не
    # проверяем — оно в $ZF_SERVICE, и активный сервис это мы сами.
    local other
    for other in zapret2 zapret; do
        [[ "$other" == "$ZF_SERVICE" ]] && continue
        if [[ "$(systemctl is-active "$other" 2>/dev/null)" == "active" ]]; then
            printf '  WARN  активен сервис %s — конфликт за NFQUEUE\n' "$other"
            warn=$((warn + 1))
        fi
    done

    (( warn == 0 )) && printf '  OK    окружение чистое\n'
    return 0
}
