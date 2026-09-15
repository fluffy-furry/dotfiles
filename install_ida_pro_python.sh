#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

common::require_target_user

run_as_target() {
    common::run_as_target "$1"
}

DEFAULT_PYVER="3.14.7"
PYVER=""
VERBOSE=false
REBUILD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
        ;;
        --rebuild)
            REBUILD=true
            shift
        ;;
        --help|-h)
            common::step "Usage: $0 [--verbose|-v] [--rebuild] [PYVER]"
            common::detail "Example: $0 --verbose 3.14.7"
            exit 0
        ;;
        -*)
            common::die "Unknown option: $1"
        ;;
        *)
            if [[ -z "$PYVER" ]]; then
                PYVER="$1"
            else
                common::warn "Extra argument: $1 (ignoring)"
            fi
            shift
        ;;
    esac
done

PYVER="${PYVER:-$DEFAULT_PYVER}"

if [[ ! "$PYVER" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    common::die "Python version must be a numeric major.minor or major.minor.patch value: $PYVER"
fi

REQUESTED_PYVER="$PYVER"
PYTHON_CONFIGURE_OPTS="--enable-shared --enable-optimizations --with-lto"
PYTHON_CFLAGS="-march=native -mtune=native"

run_as_target 'command -v pyenv >/dev/null 2>&1' || common::die "pyenv not found for $TARGET_USER."

PYVER="$(run_as_target "pyenv latest -k '$REQUESTED_PYVER'")" || \
    common::die "No pyenv CPython definition matches $REQUESTED_PYVER."
if [[ ! "$PYVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    common::die "Resolved pyenv version is not a stable CPython release: $PYVER"
fi
PYENV_NAME="ida-$PYVER"
common::step "Resolved Python $REQUESTED_PYVER to $PYVER (pyenv name: $PYENV_NAME)."

common::step "Searching for IDA installations..."
ida_candidates=()
shopt -s nullglob
for p in /opt/*IDA* /opt/*ida* /usr/local/*IDA* /usr/local/*ida* \
    "$TARGET_HOME"/.local/*IDA* "$TARGET_HOME"/.local/*ida* \
    "$TARGET_HOME"/IDA* "$TARGET_HOME"/*IDA* "$TARGET_HOME"/*ida*; do
    [[ -e "$p" ]] && ida_candidates+=("$p")
done
shopt -u nullglob

tmp=()
for p in "${ida_candidates[@]:-}"; do
    [[ -d "$p" ]] && tmp+=("$p")
done
ida_candidates=("${tmp[@]}")

if [ ${#ida_candidates[@]} -eq 0 ]; then
    while IFS= read -r -d $'\0' d; do
        ida_candidates+=("$d")
    done < <(find /opt /usr/local "$TARGET_HOME" -maxdepth 4 \( -type d -name "*IDA*" -o -type d -name "*ida*" \) -print0 2>/dev/null || true)
fi

[ ${#ida_candidates[@]} -gt 0 ] || common::die "No IDA installations found under /opt, /usr/local, or home."

best=""
best_ver=""

for p in "${ida_candidates[@]}"; do
    name="$(basename "$p")"
    ver="$(echo "$name" | grep -oE '[0-9]+(\.[0-9]+)+' || true)"
    if [[ -n "$ver" ]]; then
        if [[ -z "$best_ver" || "$(printf "%s\n%s\n" "$ver" "$best_ver" | sort -V | tail -n1)" == "$ver" ]]; then
            best="$p"
            best_ver="$ver"
        fi
    fi
done

if [[ -z "$best" ]]; then
    common::step "No numeric version found — picking most recent by modification time."
    newest=""
    newest_mtime=0
    for p in "${ida_candidates[@]}"; do
        mtime="$(stat -c %Y "$p" 2>/dev/null || echo 0)"
        if (( mtime > newest_mtime )); then
            newest_mtime=$mtime
            newest="$p"
        fi
    done
    best="$newest"
fi

IDA_APP="$best"
IDA_SWITCH=""

if [ -n "$IDA_APP" ]; then
    found_switch="$(find "$IDA_APP" -maxdepth 6 -type f -name "idapyswitch" -executable -print -quit 2>/dev/null || true)"
    if [[ -n "$found_switch" ]]; then
        IDA_SWITCH="$found_switch"
    else
        found_switch="$(find "$IDA_APP" -maxdepth 6 -type f -iname "idapyswitch*" -print -quit 2>/dev/null || true)"
        IDA_SWITCH="$found_switch"
    fi
fi

common::step "Detected IDA: $IDA_APP"
[ -n "$IDA_SWITCH" ] || common::die "idapyswitch not found under $IDA_APP"
[ -x "$IDA_SWITCH" ] || common::warn "idapyswitch found but not executable: $IDA_SWITCH"

if run_as_target "pyenv versions --bare | grep -qx '$PYENV_NAME'"; then
    if [[ "$REBUILD" == true ]]; then
        common::warn "Rebuilding the existing IDA-specific pyenv version $PYENV_NAME."
        run_as_target "pyenv uninstall -f '$PYENV_NAME'"
    else
        common::step "Reusing existing IDA-specific pyenv version $PYENV_NAME."
    fi
fi

if ! run_as_target "pyenv versions --bare | grep -qx '$PYENV_NAME'"; then
    common::step "Building Python $PYVER as $PYENV_NAME..."
    BUILD_ENV="env PYTHON_CONFIGURE_OPTS='$PYTHON_CONFIGURE_OPTS' PYTHON_CFLAGS='$PYTHON_CFLAGS'"
    if [[ "$VERBOSE" == true ]]; then
        run_as_target "$BUILD_ENV pyenv install --verbose '$PYVER:$PYENV_NAME'"
    else
        run_as_target "$BUILD_ENV pyenv install '$PYVER:$PYENV_NAME'"
    fi
fi

PYENV_PFX="$(run_as_target "pyenv prefix '$PYENV_NAME'")"
LIBPY=""
PYTHON_ABI="${PYVER%.*}"

shopt -s nullglob
candidates=( "$PYENV_PFX"/lib/libpython${PYTHON_ABI}*.so* )
shopt -u nullglob

if [ ${#candidates[@]} -gt 0 ]; then
    sorted=()
    while IFS= read -r candidate; do
        sorted+=("$candidate")
    done < <(printf '%s\n' "${candidates[@]}" | sort -V)
    LIBPY="${sorted[0]}"
else
    LIBPY="$(find "$PYENV_PFX/lib" -maxdepth 1 \( -type f -o -type l \) -name "libpython${PYTHON_ABI}*.so*" -print | sort -V | head -n1 || true)"
fi

common::step "Build complete: $PYENV_PFX"
if [ -z "$LIBPY" ]; then
    common::die "libpython shared object not found under $PYENV_PFX/lib for Python $PYVER. Rerun with --rebuild."
fi

common::step "Switching IDA python version..."
if [ -x "$IDA_SWITCH" ]; then
    common::exec_as_target "$IDA_SWITCH" --force-path "$LIBPY" || {
        common::warn "idapyswitch failed. Try manually:"
        common::detail "  $IDA_SWITCH --force-path $LIBPY" >&2
        common::die "Registration failed."
    }
else
    common::warn "idapyswitch is not executable: $IDA_SWITCH"
    common::detail "Try: chmod +x \"$IDA_SWITCH\" && \"$IDA_SWITCH\" --force-path \"$LIBPY\"" >&2
    common::die "Registration failed."
fi

common::summary "IDA Pro registered with Python $PYVER"
