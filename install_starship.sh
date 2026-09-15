#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

readonly CONFIG_MARKER="# Managed by install_starship.sh; local changes will be replaced."
readonly ZSHRC_BEGIN="# >>> Starship prompt (managed by install_starship.sh) >>>"
readonly ZSHRC_END="# <<< Starship prompt (managed by install_starship.sh) <<<"

TARGET_CONFIG_HOME=""
STARSHIP_CONFIG=""
STARSHIP_BIN=""
TEMP_INSTALLER=""
TEMP_PRESET=""
TEMP_CONFIG=""
TEMP_ZSHRC=""

starship::cleanup() {
    [[ -z "$TEMP_INSTALLER" ]] || rm -f -- "$TEMP_INSTALLER" || true
    [[ -z "$TEMP_PRESET" ]] || common::exec_as_target rm -f -- "$TEMP_PRESET" || true
    [[ -z "$TEMP_CONFIG" ]] || common::exec_as_target rm -f -- "$TEMP_CONFIG" || true
    [[ -z "$TEMP_ZSHRC" ]] || common::exec_as_target rm -f -- "$TEMP_ZSHRC" || true
}

starship::run_privileged() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
        return
    fi
    command -v sudo >/dev/null 2>&1 ||
        common::die "sudo is required to install missing system packages."
    sudo -- "$@"
}

starship::assert_target_owned() {
    local path="$1"
    local owner

    [[ -e "$path" ]] || return 0
    owner="$(stat -c '%U' -- "$path")"
    [[ "$owner" == "$TARGET_USER" ]] ||
        common::die "$path is owned by $owner, not $TARGET_USER. Refusing to replace it."
}

starship::ensure_dependencies() {
    local -a packages=()

    [[ "$(uname -s)" == "Linux" ]] ||
        common::die "This installer currently supports Linux only."

    command -v zsh >/dev/null 2>&1 || packages+=(zsh)
    command -v curl >/dev/null 2>&1 || packages+=(curl)

    if [[ "${#packages[@]}" -eq 0 ]]; then
        common::detail "zsh and curl are already installed"
    else
        command -v apt-get >/dev/null 2>&1 ||
            common::die "Missing ${packages[*]}; install them with your package manager, then rerun."
        common::step "Installing missing packages: ${packages[*]}"
        starship::run_privileged apt-get update
        starship::run_privileged apt-get install -y "${packages[@]}"
        common::detail "Installed missing packages"
    fi

    for command_name in awk grep install mkdir mktemp stat tar zsh; do
        command -v "$command_name" >/dev/null 2>&1 ||
            common::die "Missing required command: $command_name"
    done
}

starship::find_binary() {
    local candidate

    STARSHIP_BIN="$(common::run_as_target 'command -v starship' 2>/dev/null || true)"
    STARSHIP_BIN="${STARSHIP_BIN##*$'\n'}"
    if [[ -n "$STARSHIP_BIN" ]] && [[ -x "$STARSHIP_BIN" ]]; then
        return 0
    fi

    for candidate in /usr/local/bin/starship /usr/bin/starship; do
        if [[ -x "$candidate" ]]; then
            STARSHIP_BIN="$candidate"
            return 0
        fi
    done
    STARSHIP_BIN=""
    return 1
}

starship::install_binary() {
    if starship::find_binary; then
        common::detail "Starship is already installed: $STARSHIP_BIN"
        return
    fi

    TEMP_INSTALLER="$(mktemp "${TMPDIR:-/tmp}/starship-installer.XXXXXXXX")"
    common::step "Downloading the official Starship installer..."
    if ! curl --fail --location --silent --show-error --retry 3 \
        --proto '=https' --proto-redir '=https' \
        https://starship.rs/install.sh --output "$TEMP_INSTALLER"; then
        common::die "Could not download the Starship installer."
    fi

    common::step "Installing Starship system-wide..."
    starship::run_privileged sh "$TEMP_INSTALLER" -y
    starship::find_binary ||
        common::die "Starship installation completed, but its executable was not found."
    common::detail "Installed Starship: $STARSHIP_BIN"
}

starship::prepare_config_target() {
    TARGET_CONFIG_HOME="$TARGET_HOME/.config"
    STARSHIP_CONFIG="$TARGET_CONFIG_HOME/starship.toml"

    if [[ -L "$TARGET_CONFIG_HOME" ]]; then
        common::die "Refusing to write through a symbolic-link config directory: $TARGET_CONFIG_HOME"
    fi
    if [[ -e "$TARGET_CONFIG_HOME" ]] && [[ ! -d "$TARGET_CONFIG_HOME" ]]; then
        common::die "Config path is not a directory: $TARGET_CONFIG_HOME"
    fi
    common::exec_as_target mkdir -p -- "$TARGET_CONFIG_HOME"

    if [[ -L "$STARSHIP_CONFIG" ]]; then
        common::die "Refusing to replace a symbolic-link Starship config: $STARSHIP_CONFIG"
    fi
    if [[ -e "$STARSHIP_CONFIG" ]] && [[ ! -f "$STARSHIP_CONFIG" ]]; then
        common::die "Starship config is not a regular file: $STARSHIP_CONFIG"
    fi
    if [[ -f "$STARSHIP_CONFIG" ]]; then
        starship::assert_target_owned "$STARSHIP_CONFIG"
        if ! grep -Fqx "$CONFIG_MARKER" "$STARSHIP_CONFIG"; then
            common::die "Refusing to replace unmanaged Starship config: $STARSHIP_CONFIG"
        fi
    fi

    TEMP_PRESET="$(common::exec_as_target mktemp "$TARGET_CONFIG_HOME/.starship-preset.XXXXXXXX")"
    TEMP_CONFIG="$(common::exec_as_target mktemp "$TARGET_CONFIG_HOME/.starship-config.XXXXXXXX")"
}

starship::write_catppuccin_config() {
    local config_mode

    if [[ -f "$STARSHIP_CONFIG" ]]; then
        config_mode="$(stat -c '%a' -- "$STARSHIP_CONFIG")"
    else
        config_mode="0644"
    fi

    common::step "Generating the Catppuccin Powerline preset without time..."
    common::exec_as_target \
        "$STARSHIP_BIN" preset catppuccin-powerline --force -o "$TEMP_PRESET"

    if ! awk -v marker="$CONFIG_MARKER" '
        BEGIN {
            print marker
            separator = "^[[:space:]]*\\[\\]\\(fg:sapphire bg:lavender\\)\\\\[[:space:]]*$"
            time_line = "^[[:space:]]*\\$time\\\\[[:space:]]*$"
            trailing_separator = "^[[:space:]]*\\[ \\]\\(fg:lavender\\)\\\\[[:space:]]*$"
            time_header = "^[[:space:]]*\\[time\\][[:space:]]*$"
            section_header = "^[[:space:]]*\\["
        }
        $0 ~ separator {
            replacement = $0
            if ((getline next_line) <= 0 || next_line !~ time_line ||
                (getline end_line) <= 0 || end_line !~ trailing_separator) {
                exit 1
            }
            sub(/\[\]\(fg:sapphire bg:lavender\)/, "[ ](fg:sapphire)", replacement)
            print replacement
            format_removed = 1
            next
        }
        $0 ~ time_header {
            while ((getline next_line) > 0) {
                if (next_line ~ section_header) {
                    print next_line
                    break
                }
            }
            if (next_line !~ section_header) {
                exit 1
            }
            time_removed = 1
            next
        }
        { print }
        END {
            if (!format_removed || !time_removed) {
                exit 1
            }
        }
    ' "$TEMP_PRESET" > "$TEMP_CONFIG"; then
        common::die "The installed Catppuccin preset changed; could not safely remove its time module."
    fi

    if grep -Fq '$time' "$TEMP_CONFIG" ||
        grep -Eq '^[[:space:]]*\[time\][[:space:]]*$' "$TEMP_CONFIG"; then
        common::die "The generated Starship config still contains the time module."
    fi

    common::exec_as_target install -m "$config_mode" -- "$TEMP_CONFIG" "$STARSHIP_CONFIG"
    common::detail "Installed Catppuccin Powerline config without time: $STARSHIP_CONFIG"
}

starship::configure_zsh() {
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
    starship::assert_target_owned "$zshrc"
    zshrc_mode="$(stat -c '%a' -- "$zshrc")"

    TEMP_ZSHRC="$(common::exec_as_target mktemp "$TARGET_HOME/.zshrc.starship.XXXXXXXX")"
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
        common::die "The existing managed Starship block in $zshrc is incomplete."
    fi

    printf '%s\n' \
        "$ZSHRC_BEGIN" \
        "eval \"\$(\"$STARSHIP_BIN\" init zsh)\"" \
        "$ZSHRC_END" >> "$TEMP_ZSHRC"

    common::exec_as_target install -m "$zshrc_mode" -- "$TEMP_ZSHRC" "$zshrc"
    common::detail "Enabled Starship in $zshrc"
}

main() {
    common::require_target_user

    trap starship::cleanup EXIT

    common::step 'Setting up Starship'
    common::detail "Target user: $TARGET_USER"
    starship::ensure_dependencies
    starship::install_binary
    starship::prepare_config_target
    starship::write_catppuccin_config
    starship::configure_zsh

    common::step 'Caveats'
    common::detail 'Start Zsh with: exec zsh'
    common::summary 'Starship configured with Catppuccin Powerline'
}

main "$@"
