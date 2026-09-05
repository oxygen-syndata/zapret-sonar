#!/usr/bin/env bash
# ============================================================================
# install.sh — установка zapret-sonar
#
# Ставит три вещи:
#   1. zapret v1 (bol-van) в /opt/zapret — он делает firewall, systemd, демона;
#   2. стратегии, .bin-фейки и списки Flowseal рядом, в flowseal-*;
#   3. сам zapret-sonar в /usr/local/bin.
#
# Принципы:
#   • Всё скачивается в staging и заменяется только после проверки — сбой
#     сети не должен оставить систему без рабочего обхода.
#   • sha256 бинарников сверяется с sha256sum.txt из релиза.
#   • Файлы в /opt принадлежат root:root. Пользовательские списки — тоже:
#     правки идут через `zapret-sonar site`, которая поднимает права сама.
#     Записываемый пользователем бинарник, запускаемый от root, — это
#     готовая эскалация привилегий.
#   • sudoers не трогается. Пароль спрашивается штатным sudo.
# ============================================================================

set -euo pipefail

ZAPRET_VER="${ZAPRET_VER:-v72.13}"
FLOWSEAL_VER="${FLOWSEAL_VER:-1.10.2}"

ZAPRET_BASE="${ZAPRET_BASE:-/opt/zapret}"
BIN_DEST="${BIN_DEST:-/usr/local/bin}"
SERVICE_NAME="${SERVICE_NAME:-zapret}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING=""

# Пути к распакованным исходникам. Через глобальные переменные, а не через
# stdout функций: иначе прогресс-вывод попал бы в захватываемое значение.
FETCHED_ZAPRET=""
FETCHED_FLOWSEAL=""

log()  { printf '\n>>> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nошибка: %s\n' "$*" >&2; exit 1; }

cleanup() { [[ -n "$STAGING" && -d "$STAGING" ]] && rm -rf "$STAGING"; }
trap cleanup EXIT

# --- Проверки ----------------------------------------------------------------
# --- Чужой обитатель каталога ------------------------------------------------
# В /opt/zapret может стоять другой проект — в частности zapret-ng, который
# использует и тот же путь, и то же имя systemd-юнита. Копирование поверх дало
# бы смесь двух проектов, а перезапись юнита молча сломала бы предыдущий.
# Поэтому такое состояние обнаруживается и требует явного решения.
detect_occupant() {
    local f
    # Файлы, которых нет у zapret v1, но есть у zapret-ng.
    for f in conf.env zapret-ctl service.sh update-strategies; do
        [[ -e "$ZAPRET_BASE/$f" ]] && { printf 'zapret-ng\n'; return 0; }
    done
    # Наша же прошлая установка: есть init.d от zapret v1.
    [[ -f "$ZAPRET_BASE/init.d/sysv/functions" ]] && { printf 'zapret\n'; return 0; }
    [[ -d "$ZAPRET_BASE" ]] && [[ -n "$(ls -A "$ZAPRET_BASE" 2>/dev/null)" ]] && { printf 'unknown\n'; return 0; }
    printf 'none\n'
}

unit_is_foreign() {
    local u="/etc/systemd/system/$SERVICE_NAME.service"
    [[ -f "$u" ]] || return 1
    # Юнит zapret v1 запускает init.d/sysv/zapret. Всё остальное — чужое.
    grep -q 'init.d/sysv/zapret' "$u" && return 1
    return 0
}

preflight() {
    [[ $EUID -eq 0 ]] || die "запускать от root: sudo ./install.sh"

    local missing=()
    local c
    for c in curl tar sha256sum systemctl; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) || die "не хватает утилит: ${missing[*]}"

    # nfqws работает через NFQUEUE, нужен хотя бы один backend.
    if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
        die "нужен nftables (nft) или iptables"
    fi
    command -v nft >/dev/null 2>&1 || info "ПРЕДУПРЕЖДЕНИЕ: nft не найден, zapret пойдёт через iptables"

    [[ -d /run/systemd/system ]] || die "systemd не обнаружен — этот установщик рассчитан на systemd"

    local f
    for f in zapret-sonar lib/translate.sh lib/zconfig.sh lib/health.sh; do
        [[ -f "$SRC_DIR/$f" ]] || die "рядом с install.sh нет $f"
    done

    # Занятый каталог и чужой юнит — повод остановиться, а не «доустановить».
    local occ; occ=$(detect_occupant)
    case "$occ" in
        none|zapret) ;;
        zapret-ng)
            printf '\nВ %s установлен zapret-ng (другой проект).\n' "$ZAPRET_BASE" >&2
            printf 'Копирование поверх дало бы смесь двух проектов.\n' >&2
            printf 'Сначала сохраните и уберите его, либо ставьте в другой путь:\n' >&2
            printf '  ZAPRET_BASE=/opt/zapret-sonar SERVICE_NAME=zapret-sonar ./install.sh\n' >&2
            die "каталог занят: zapret-ng"
            ;;
        *)
            printf '\nВ %s есть посторонние файлы (неизвестный проект).\n' "$ZAPRET_BASE" >&2
            die "каталог занят — очистите его или укажите другой ZAPRET_BASE"
            ;;
    esac

    if unit_is_foreign; then
        printf '\nЮнит %s.service принадлежит другому проекту.\n' "$SERVICE_NAME" >&2
        printf 'Перезапись молча сломала бы его. Укажите другое имя:\n' >&2
        printf '  SERVICE_NAME=zapret-sonar ./install.sh\n' >&2
        die "имя сервиса занято: $SERVICE_NAME"
    fi
}

detect_arch() {
    local m; m=$(uname -m)
    case "$m" in
        x86_64|amd64) printf 'linux-x86_64\n' ;;
        i?86)         printf 'linux-x86\n' ;;
        aarch64|arm64) printf 'linux-arm64\n' ;;
        armv7l|armv6l|arm) printf 'linux-arm\n' ;;
        *) die "неизвестная архитектура: $m (нет готовых бинарников)" ;;
    esac
}

# --- Скачивание --------------------------------------------------------------
fetch_zapret() {
    local arch="$1" url sums
    url="https://github.com/bol-van/zapret/releases/download/$ZAPRET_VER/zapret-$ZAPRET_VER.tar.gz"
    sums="https://github.com/bol-van/zapret/releases/download/$ZAPRET_VER/sha256sum.txt"

    log "Скачивание zapret $ZAPRET_VER ($arch)"
    curl -fsSL --retry 2 -o "$STAGING/zapret.tar.gz" "$url" || die "не скачался zapret"
    curl -fsSL --retry 2 -o "$STAGING/sha256sum.txt" "$sums" || die "не скачался sha256sum.txt"

    tar -xzf "$STAGING/zapret.tar.gz" -C "$STAGING" || die "архив zapret не распаковался"
    local root="$STAGING/zapret-$ZAPRET_VER"
    [[ -d "$root" ]] || die "в архиве нет каталога zapret-$ZAPRET_VER"

    # sha256sum.txt содержит хеши бинарников внутри архива (не самого архива),
    # пути в нём относительно распакованного каталога.
    log "Проверка целостности бинарников"
    ( cd "$STAGING" && sha256sum -c --ignore-missing --quiet sha256sum.txt 2>/dev/null ) \
        || die "sha256 не совпал — скачанные бинарники повреждены или подменены"

    local nfqws="$root/binaries/$arch/nfqws"
    [[ -f "$nfqws" ]] || die "в релизе нет бинарника для $arch"
    # Пере-проверка целевого бинарника отдельно: --ignore-missing выше мог
    # пропустить его, если строки для этой арки в файле нет.
    grep -q "binaries/$arch/nfqws" "$STAGING/sha256sum.txt" \
        || die "в sha256sum.txt нет записи для $arch/nfqws — целостность не подтверждена"
    info "nfqws $arch: sha256 подтверждён"
    FETCHED_ZAPRET="$root"
}

fetch_flowseal() {
    local url
    url="https://github.com/Flowseal/zapret-discord-youtube/releases/download/$FLOWSEAL_VER/zapret-discord-youtube-$FLOWSEAL_VER.tar.gz"

    log "Скачивание стратегий Flowseal $FLOWSEAL_VER"
    # У Flowseal нет файла с контрольными суммами в релизе; целостность
    # обеспечивается только TLS. Сообщаем честно.
    info "у релиза Flowseal нет sha256-файла — доверяем TLS"
    curl -fsSL --retry 2 -o "$STAGING/flowseal.tar.gz" "$url" || die "не скачались стратегии"

    mkdir -p "$STAGING/fs"
    tar -xzf "$STAGING/flowseal.tar.gz" -C "$STAGING/fs" || die "архив Flowseal не распаковался"

    # В архиве возможен как корень с файлами, так и вложенный каталог.
    local root
    root=$(find "$STAGING/fs" -maxdepth 2 -name 'general*.bat' -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$root" ]] || die "в архиве Flowseal не найдено стратегий general*.bat"
    [[ -d "$root/bin" && -d "$root/lists" ]] || die "в архиве Flowseal нет bin/ или lists/"
    FETCHED_FLOWSEAL="$root"
}

# --- Установка ---------------------------------------------------------------
install_zapret() {
    local src="$1" arch="$2"

    # Конфиг — единственное, что нельзя потерять при переустановке.
    local saved=""
    if [[ -f "$ZAPRET_BASE/config" ]]; then
        saved="$STAGING/config.saved"
        cp -a "$ZAPRET_BASE/config" "$saved"
        info "текущий config сохранён и будет возвращён"
    fi

    log "Установка zapret в $ZAPRET_BASE"
    mkdir -p "$ZAPRET_BASE"
    # Обновляем содержимое, не удаляя каталог целиком: так переустановка не
    # оставляет систему без файлов при обрыве.
    cp -a "$src/." "$ZAPRET_BASE/"

    install -Dm755 "$src/binaries/$arch/nfqws" "$ZAPRET_BASE/nfq/nfqws"
    [[ -f "$src/binaries/$arch/ip2net" ]] && install -Dm755 "$src/binaries/$arch/ip2net" "$ZAPRET_BASE/ip2net/ip2net"
    [[ -f "$src/binaries/$arch/mdig" ]]   && install -Dm755 "$src/binaries/$arch/mdig"   "$ZAPRET_BASE/mdig/mdig"

    [[ -n "$saved" ]] && cp -a "$saved" "$ZAPRET_BASE/config"
    chown -R root:root "$ZAPRET_BASE"
    info "nfqws: $("$ZAPRET_BASE/nfq/nfqws" --version 2>&1 | head -1)"
}

install_flowseal() {
    local src="$1"
    log "Установка стратегий и списков Flowseal"

    local sdir="$ZAPRET_BASE/flowseal-strategies"
    local bdir="$ZAPRET_BASE/flowseal-bin"
    local ldir="$ZAPRET_BASE/flowseal-lists"
    mkdir -p "$sdir" "$bdir" "$ldir"

    local f
    for f in "$src"/*.bat; do
        # service.bat — windows-утилита управления, не стратегия.
        [[ "$(basename "$f")" == service.bat ]] && continue
        install -m 644 "$f" "$sdir/"
    done

    install -m 644 "$src/bin/"*.bin "$bdir/" 2>/dev/null || die "не скопировались .bin-фейки"

    # Списки не перезаписываем, если уже есть: в них пользовательские домены.
    # Копируем все файлы (включая .backup), не только *.txt.
    for f in "$src/lists/"*; do
        [[ -f "$f" ]] || continue
        local base; base=$(basename "$f")
        if [[ -f "$ldir/$base" ]]; then
            info "сохранён существующий $base"
        else
            install -m 644 "$f" "$ldir/"
        fi
    done

    # Flowseal создаёт *-user.txt при первом запуске на Windows. Стратегии
    # ссылаются на них всегда, а nfqws падает на отсутствующем файле.
    for f in list-general-user.txt list-exclude-user.txt ipset-exclude-user.txt; do
        [[ -f "$ldir/$f" ]] || { : > "$ldir/$f"; chmod 644 "$ldir/$f"; }
    done

    chown -R root:root "$sdir" "$bdir" "$ldir"
    printf '%s\n' "$FLOWSEAL_VER" > "$ZAPRET_BASE/.flowseal-version"
    info "стратегий: $(find "$sdir" -name '*.bat' | wc -l), фейков: $(find "$bdir" -name '*.bin' | wc -l)"
}

install_flow() {
    log "Установка zapret-sonar в $BIN_DEST"
    local dest="$ZAPRET_BASE/zapret-sonar"
    mkdir -p "$dest/lib"
    install -m 755 "$SRC_DIR/zapret-sonar" "$dest/zapret-sonar"
    install -m 644 "$SRC_DIR/lib/"*.sh "$dest/lib/"

    # Фиксируем пути установки. Переменные окружения тут не годятся: CLI
    # перезапускает себя через sudo, который окружение не пробрасывает.
    cat > "$dest/lib/paths.sh" <<EOF
# Сгенерировано install.sh — путь и имя сервиса этой установки.
# Значения заданы установщиком, но допускают override через окружение
# (нужно для тестирования и нестандартных конфигураций).
ZF_ZAPRET_BASE="\${ZF_ZAPRET_BASE:-$ZAPRET_BASE}"
ZF_SERVICE="\${ZF_SERVICE:-$SERVICE_NAME}"
EOF
    chmod 644 "$dest/lib/paths.sh"

    ln -sf "$dest/zapret-sonar" "$BIN_DEST/zapret-sonar"
    ln -sf "$dest/zapret-sonar" "$BIN_DEST/sonar"

    # TUI ставится, только если рядом лежит и есть fzf: на headless-сервере
    # он бесполезен, а тянуть зависимость ради неиспользуемого файла незачем.
    if [[ -f "$SRC_DIR/zapret-sonar-tui" ]]; then
        install -m 755 "$SRC_DIR/zapret-sonar-tui" "$dest/zapret-sonar-tui"
        ln -sf "$dest/zapret-sonar-tui" "$BIN_DEST/zapret-sonar-tui"
        ln -sf "$dest/zapret-sonar-tui" "$BIN_DEST/sonar-tui"
        if command -v fzf >/dev/null 2>&1; then
            info "TUI: zapret-sonar-tui"
        else
            info "TUI установлен, но нужен fzf (без него не запустится)"
        fi
    fi

    chown -R root:root "$dest"
    info "команда: zapret-sonar --help (или: sonar --help)"
}

install_unit() {
    log "Установка systemd-юнита"
    # Юнит берём из самого zapret: он знает свою схему запуска
    # (init.d/sysv/zapret start|stop, Type=forking).
    local src="$ZAPRET_BASE/init.d/systemd/zapret.service"
    [[ -f "$src" ]] || die "в zapret нет init.d/systemd/zapret.service"

    # Пути в юните жёстко прописаны как /opt/zapret — правим, если ставим не туда.
    sed "s|/opt/zapret|$ZAPRET_BASE|g" "$src" > "/etc/systemd/system/$SERVICE_NAME.service"
    chmod 644 "/etc/systemd/system/$SERVICE_NAME.service"
    systemctl daemon-reload
    info "юнит: /etc/systemd/system/$SERVICE_NAME.service (автозапуск не включён)"
}

check_conflicts() {
    local other
    for other in zapret2 zapret-ng; do
        [[ "$other" == "$SERVICE_NAME" ]] && continue
        if [[ "$(systemctl is-active "$other" 2>/dev/null)" == "active" ]]; then
            printf '\nВНИМАНИЕ: активен сервис %s — он займёт NFQUEUE и будет конфликтовать.\n' "$other"
            printf 'Остановите его перед запуском: systemctl stop %s\n' "$other"
        fi
        if [[ "$(systemctl is-enabled "$other" 2>/dev/null)" == "enabled" ]]; then
            printf 'ВНИМАНИЕ: %s включён в автозапуск — после перезагрузки поднимется вместе с zapret.\n' "$other"
        fi
    done
}

main() {
    preflight
    local arch; arch=$(detect_arch)
    STAGING=$(mktemp -d /tmp/zapret-sonar-install.XXXXXX)

    fetch_zapret "$arch"
    fetch_flowseal

    install_zapret "$FETCHED_ZAPRET" "$arch"
    install_flowseal "$FETCHED_FLOWSEAL"
    install_flow
    install_unit
    check_conflicts

    cat <<EOF

Готово.

  zapret-sonar baseline          что заблокировано без обхода
  zapret-sonar try               перебрать стратегии и найти рабочие
  zapret-sonar use <стратегия>   применить
  zapret-sonar status            состояние

Автозапуск (после того как нашли рабочую стратегию):
  systemctl enable $SERVICE_NAME

Стратегии подбираются опытом: рабочая зависит от провайдера.
EOF
}

main "$@"
