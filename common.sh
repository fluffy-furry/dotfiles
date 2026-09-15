#!/usr/bin/env bash

common::use_color() {
    [[ -z "${NO_COLOR+x}" && -z "${DOTFILES_NO_COLOR:-}" ]] &&
        { [[ -n "${DOTFILES_COLOR:-}" ]] || { [[ -t 1 ]] && [[ "${TERM:-}" != dumb ]]; }; }
}

common::message() {
    local prefix="$1" color="$2" bold="$3" message="$4"

    if common::use_color; then
        printf '\033[%sm%s\033[0m ' "$color" "$prefix"
        if [[ "$bold" == true ]]; then
            printf '\033[1m%s\033[0m\n' "$message"
        else
            printf '%s\n' "$message"
        fi
    else
        printf '%s %s\n' "$prefix" "$message"
    fi
}

common::step() {
    common::message '==>' 34 true "$*"
}

common::detail() {
    printf '%s\n' "$*"
}

common::warn() {
    common::message 'Warning:' 33 false "$*" >&2
}

common::error() {
    common::message 'Error:' 31 false "$*" >&2
}

common::die() {
    common::error "$*"
    exit 1
}

common::summary() {
    common::step 'Summary'
    printf '📦  %s\n' "$1"
}

common::refuse_root_user_install() {
    local install_mode="${1:-user}"

    if [[ "$install_mode" == "--system" ]]; then
        install_mode="system"
    fi

    if [[ "$install_mode" != "system" ]] && [[ "$EUID" -eq 0 ]]; then
        common::die 'Refusing to run user install as root. Re-run without sudo, or use --system.'
    fi
}

common::resolve_target_user() {
    if [[ "$EUID" -eq 0 ]]; then
        TARGET_USER="${SUDO_USER:-}"
        if [[ -z "$TARGET_USER" ]]; then
            return 1
        fi
        TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
        if [[ -z "$TARGET_HOME" ]]; then
            TARGET_HOME="/home/$TARGET_USER"
        fi
        AS_ROOT=true
    else
        TARGET_USER="$USER"
        TARGET_HOME="$HOME"
        AS_ROOT=false
    fi
}

common::require_target_user() {
    common::resolve_target_user ||
        common::die 'Refusing to run as root without an invoking user. Run as your user or with sudo from your account.'
}

common::run_as_target() {
    local command="$1"
    if [[ "${AS_ROOT:-false}" == true ]]; then
        sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" bash -lc "$command"
    else
        HOME="$TARGET_HOME" bash -lc "$command"
    fi
}

common::exec_as_target() {
    if [[ "${AS_ROOT:-false}" == true ]]; then
        sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" "$@"
    else
        HOME="$TARGET_HOME" "$@"
    fi
}
