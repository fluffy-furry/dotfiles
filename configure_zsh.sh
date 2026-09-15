#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

readonly ZSHRC_BEGIN="# >>> Zsh settings (managed by configure_zsh.sh) >>>"
readonly ZSHRC_END="# <<< Zsh settings (managed by configure_zsh.sh) <<<"

TEMP_ZSHRC=""

zsh_setup::cleanup() {
    [[ -z "$TEMP_ZSHRC" ]] || common::exec_as_target rm -f -- "$TEMP_ZSHRC" || true
}

zsh_setup::assert_target_owned() {
    local path="$1"
    local owner

    [[ -e "$path" ]] || return 0
    owner="$(stat -c '%U' -- "$path")"
    [[ "$owner" == "$TARGET_USER" ]] ||
        common::die "$path is owned by $owner, not $TARGET_USER. Refusing to replace it."
}

zsh_setup::configure() {
    local zshrc="$TARGET_HOME/.zshrc"
    local zshrc_mode

    if [[ -L "$zshrc" ]]; then
        common::die "Refusing to update a symbolic-link Zsh config: $zshrc"
    fi
    if [[ -e "$zshrc" ]] && [[ ! -f "$zshrc" ]]; then
        common::die "Zsh config is not a regular file: $zshrc"
    fi
    if [[ ! -e "$zshrc" ]]; then
        common::exec_as_target touch -- "$zshrc"
    fi
    zsh_setup::assert_target_owned "$zshrc"
    zshrc_mode="$(stat -c '%a' -- "$zshrc")"

    TEMP_ZSHRC="$(common::exec_as_target mktemp "$TARGET_HOME/.zshrc.setup.XXXXXXXX")"
    if ! awk -v begin="$ZSHRC_BEGIN" -v end="$ZSHRC_END" '
        $0 == begin {
            if (in_block) {
                exit 1
            }
            in_block = 1
            next
        }
        $0 == end {
            if (!in_block) {
                exit 1
            }
            in_block = 0
            next
        }
        !in_block {
            print
            last_line = $0
            output_lines++
        }
        END {
            if (in_block) {
                exit 1
            }
            if (output_lines && last_line != "") {
                print ""
            }
        }
    ' "$zshrc" > "$TEMP_ZSHRC"; then
        common::die "The existing managed Zsh block in $zshrc is incomplete."
    fi

    printf '%s\n' \
        "$ZSHRC_BEGIN" \
        'HISTFILE="${HISTFILE:-${ZDOTDIR:-$HOME}/.zsh_history}"' \
        'HISTSIZE=1000000' \
        'SAVEHIST=1000000' \
        'setopt APPEND_HISTORY EXTENDED_HISTORY' \
        'if [[ ! -o SHARE_HISTORY && ! -o INC_APPEND_HISTORY_TIME ]]; then' \
        '    setopt INC_APPEND_HISTORY' \
        'fi' \
        'if (( ! ${+functions[compdef]} )); then' \
        '    autoload -Uz compinit' \
        '    compinit' \
        'fi' \
        'zmodload zsh/complist' \
        "zstyle ':completion:*' menu select" \
        "zstyle ':completion:*' matcher-list '' 'm:{a-zA-Z}={A-Za-z}'" \
        "bindkey '^R' history-incremental-search-backward" \
        "bindkey '^P' history-beginning-search-backward" \
        "bindkey '^N' history-beginning-search-forward" \
        "$ZSHRC_END" >> "$TEMP_ZSHRC"

    common::exec_as_target install -m "$zshrc_mode" -- "$TEMP_ZSHRC" "$zshrc"
    common::detail 'Enabled persistent Zsh history for up to 1,000,000 commands'
    common::detail 'Enabled completion menus and prefix history search with Ctrl+P and Ctrl+N'
}

main() {
    common::require_target_user

    trap zsh_setup::cleanup EXIT

    [[ "$(uname -s)" == "Linux" ]] ||
        common::die "This script currently supports Linux only."
    for command_name in awk install mktemp stat touch zsh; do
        command -v "$command_name" >/dev/null 2>&1 ||
            common::die "Missing required command: $command_name. Install it with your package manager, then rerun."
    done

    common::step 'Configuring Zsh'
    common::detail "Target user: $TARGET_USER"
    zsh_setup::configure

    common::step 'Caveats'
    common::detail 'Start a new Zsh session with: exec zsh'
    common::summary 'Zsh configured with persistent history and completion menus'
}

main "$@"
