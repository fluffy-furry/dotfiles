#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CONFIGURE_ALL_SHELLS=false
for argument in "$@"; do
    case "$argument" in
        --all-shells) CONFIGURE_ALL_SHELLS=true ;;
        -h|--help)
            common::detail 'Usage: install_pyenv.sh [--all-shells]'
            common::detail 'Initialize both Bash and Zsh with --all-shells; otherwise configure the login shell.'
            exit 0
        ;;
        *) common::die "Unknown option: $argument" ;;
    esac
done

common::step "Preparing pyenv installer..."

common::require_target_user

common::detail "Target user: ${TARGET_USER}"
common::detail "Target home: ${TARGET_HOME}"

DEPS=(make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
libsqlite3-dev curl git libncurses-dev xz-utils tk-dev \
libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libzstd-dev \
pkg-config libgdbm-dev libgdbm-compat-dev uuid-dev)

common::step "Checking for missing apt packages..."
TO_INSTALL=()
for pkg in "${DEPS[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        TO_INSTALL+=("$pkg")
    fi
done

if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
    common::step "Installing packages: ${TO_INSTALL[*]}"
    if [[ "$AS_ROOT" == true ]]; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${TO_INSTALL[@]}"
    else
        sudo apt-get update
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${TO_INSTALL[@]}"
    fi
    common::detail "Packages installed"
else
    common::detail "All build dependencies already present"
fi

PYENV_DIR="$TARGET_HOME/.pyenv"
PYENV_BIN="$PYENV_DIR/bin/pyenv"

if [[ -e "$PYENV_DIR" ]]; then
    FOREIGN_OWNER="$(find "$PYENV_DIR" ! -user "$TARGET_USER" -print -quit 2>/dev/null || true)"
    if [[ -n "$FOREIGN_OWNER" ]]; then
        TARGET_GROUP="$(id -gn "$TARGET_USER")"
        common::error "${PYENV_DIR} contains files not owned by ${TARGET_USER}."
        common::detail "Review them, then repair ownership once with:" >&2
        common::detail "sudo chown -R '${TARGET_USER}:${TARGET_GROUP}' -- '${PYENV_DIR}'" >&2
        exit 1
    fi
fi

if [[ -x "$PYENV_BIN" ]]; then
    common::step "Updating the existing pyenv installation for ${TARGET_USER}"
    if [[ -x "$PYENV_DIR/plugins/pyenv-update/bin/pyenv-update" ]]; then
        common::run_as_target '"$HOME/.pyenv/bin/pyenv" update'
    else
        common::run_as_target 'git -C "$HOME/.pyenv" pull --ff-only'
    fi
    common::detail "pyenv update finished"
elif [[ -e "$PYENV_DIR" ]]; then
    common::error "${PYENV_DIR} exists but does not contain an executable pyenv."
    common::detail "Move it aside after reviewing its installed Python versions, then rerun this script." >&2
    exit 1
else
    common::step "Installing pyenv via https://pyenv.run for ${TARGET_USER}"
    common::run_as_target 'curl -fsSL https://pyenv.run | bash'
    common::detail "pyenv installer finished"
fi

if [[ ! -x "$PYENV_BIN" ]]; then
    common::error "pyenv installation verification failed: ${PYENV_BIN} is not executable."
    exit 1
fi

PYENV_VERSION="$(common::run_as_target '"$HOME/.pyenv/bin/pyenv" --version')"
common::detail "Verified ${PYENV_VERSION}"

ensure_file_exists() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        common::exec_as_target touch -- "$file"
    fi
}

configure_shell_file() {
    local file="$1"
    local shell_name="$2"
    local enable_virtualenv="${3:-false}"
    local line tmp_file last_index
    local -a preserved_lines=()

    ensure_file_exists "$file"
    tmp_file="$(common::exec_as_target mktemp)"

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            'export PYENV_ROOT="$HOME/.pyenv"' | \
            'export PATH="$PYENV_ROOT/bin:$PATH"' | \
            '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' | \
            'eval "$(pyenv init --path)"' | \
            'eval "$(pyenv init -)"' | \
            'eval "$(pyenv init - bash)"' | \
            'eval "$(pyenv init - zsh)"' | \
            'eval "$(pyenv virtualenv-init -)"')
                continue
            ;;
        esac
        preserved_lines+=("$line")
    done < "$file"

    while (( ${#preserved_lines[@]} > 0 )); do
        last_index=$(( ${#preserved_lines[@]} - 1 ))
        [[ -z "${preserved_lines[$last_index]}" ]] || break
        unset "preserved_lines[$last_index]"
    done

    if (( ${#preserved_lines[@]} > 0 )); then
        printf '%s\n' "${preserved_lines[@]}" >> "$tmp_file"
        printf '\n' >> "$tmp_file"
    fi
    printf '%s\n' \
        'export PYENV_ROOT="$HOME/.pyenv"' \
        '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' \
        "eval \"\$(pyenv init - $shell_name)\"" >> "$tmp_file"
    if [[ "$enable_virtualenv" == true ]]; then
        printf '%s\n' 'eval "$(pyenv virtualenv-init -)"' >> "$tmp_file"
    fi

    if ! common::exec_as_target cp -- "$tmp_file" "$file"; then
        common::exec_as_target rm -f -- "$tmp_file"
        return 1
    fi
    common::exec_as_target rm -f -- "$tmp_file"
    common::detail "Updated $(basename "$file") for ${shell_name}"
}

TARGET_SHELL="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
SHELL_NAME="${TARGET_SHELL##*/}"
ENABLE_VIRTUALENV=false
if [[ -x "$PYENV_DIR/plugins/pyenv-virtualenv/bin/pyenv-virtualenv" ]]; then
    ENABLE_VIRTUALENV=true
fi

if [[ "$CONFIGURE_ALL_SHELLS" == true || "$SHELL_NAME" == bash ]]; then
    BASH_PROFILE="$TARGET_HOME/.profile"
    for candidate in .bash_profile .bash_login .profile; do
        if [[ -f "$TARGET_HOME/$candidate" ]]; then
            BASH_PROFILE="$TARGET_HOME/$candidate"
            break
        fi
    done
    configure_shell_file "$TARGET_HOME/.bashrc" bash "$ENABLE_VIRTUALENV"
    configure_shell_file "$BASH_PROFILE" bash false
fi

if [[ "$CONFIGURE_ALL_SHELLS" == true || "$SHELL_NAME" == zsh ]]; then
    configure_shell_file "$TARGET_HOME/.zshrc" zsh "$ENABLE_VIRTUALENV"
    configure_shell_file "$TARGET_HOME/.zprofile" zsh false
fi

if [[ "$CONFIGURE_ALL_SHELLS" == false && "$SHELL_NAME" != bash && "$SHELL_NAME" != zsh ]]; then
    common::warn "Unsupported login shell '${SHELL_NAME:-unknown}'; shell startup files were not changed."
    common::detail "Configure it with: ${PYENV_BIN} init --install" >&2
fi

common::step 'Caveats'
common::detail "Restart with: exec \"\$SHELL\""
common::summary "pyenv setup complete for ${TARGET_USER}"
