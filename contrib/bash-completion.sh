#!/usr/bin/env bash
# bash-completion для zapret-sonar / sonar
# Установка: source этот файл в ~/.bashrc или положить в /etc/bash_completion.d/

_sonar_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Первое слово — основная команда
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "list use status check try baseline update upgrade uninstall gamefilter ipset site start stop restart enable disable help --version --help" -- "$cur") )
        return 0
    fi

    # Дополнение аргументов
    case "$prev" in
        use)
            # Имена стратегий из sonar _list
            local strategies
            strategies=$(/usr/local/bin/sonar _list 2>/dev/null)
            [[ -n "$strategies" ]] && COMPREPLY=( $(compgen -W "$strategies" -- "$cur") )
            return 0 ;;
        gamefilter)
            COMPREPLY=( $(compgen -W "off tcp udp both" -- "$cur") )
            return 0 ;;
        ipset)
            COMPREPLY=( $(compgen -W "none any loaded" -- "$cur") )
            return 0 ;;
        try)
            COMPREPLY=( $(compgen -W "--keep" -- "$cur") )
            return 0 ;;
        update|upgrade)
            COMPREPLY=( $(compgen -W "--force" -- "$cur") )
            return 0 ;;
    esac

    # Для help — имена команд
    if [[ "${COMP_WORDS[1]}" == "help" ]]; then
        COMPREPLY=( $(compgen -W "list use status check try baseline update upgrade uninstall gamefilter ipset site start stop restart enable disable" -- "$cur") )
        return 0
    fi
}
complete -F _sonar_completion sonar zapret-sonar
