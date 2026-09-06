#!/usr/bin/env bash
# bash-completion для zapret-sonar / sonar
# Установка: source этот файл в ~/.bashrc или положить в /etc/bash_completion.d/

_sonar_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    if (( COMP_CWORD == 1 )); then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "list use status check try baseline update upgrade uninstall gamefilter ipset site start stop restart enable disable log help --version --help --debug" -- "$cur") )
        return 0
    fi

    case "$prev" in
        use)
            local strategies
            strategies=$(/usr/local/bin/sonar _list 2>/dev/null)
            if [[ -n "$strategies" ]]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$strategies" -- "$cur") )
            fi
            return 0 ;;
        gamefilter)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "off tcp udp both" -- "$cur") )
            return 0 ;;
        ipset)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "none any loaded" -- "$cur") )
            return 0 ;;
        try)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--keep" -- "$cur") )
            return 0 ;;
        update|upgrade)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--force" -- "$cur") )
            return 0 ;;
        site)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--list --remove" -- "$cur") )
            return 0 ;;
    esac

    if [[ "${COMP_WORDS[1]}" == "help" ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "list use status check try baseline update upgrade uninstall gamefilter ipset site start stop restart enable disable" -- "$cur") )
        return 0
    fi
}
complete -F _sonar_completion sonar zapret-sonar
