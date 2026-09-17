#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

TEMP_DIR=""
TPM_DEVICE=auto
DRACUT_MODULES=""

tpm::cleanup() {
    [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR" || true
}

tpm::usage() {
    common::detail 'Usage: sudo ./configure_tpm.sh [--device /dev/DEVICE] [--pcr7]'
    common::detail 'Choose a LUKS2 device, enroll TPM2, update crypttab, and regenerate dracut.'
    common::detail 'Installs missing dependencies on Debian/Ubuntu and Fedora, including dracut.'
    common::detail 'Installing dracut requires an interactive package-manager review.'
    common::detail 'Use --device to skip device selection. Existing setups can be kept, repaired, or re-enrolled.'
    common::detail 'Use --pcr7 to bind new or replacement enrollment to PCR 7.'
    common::detail 'Otherwise, use the systemd default PCR policy.'
    common::detail 'Keep your working LUKS passphrase/recovery key for fallback at boot.'
}

tpm::choose() {
    local keys=123456789abcdefghijklmnoprstuvwxyz
    local choice index
    local -a options=("$@")

    [[ -t 0 ]] || common::die 'Menu selection needs a terminal.'
    (( ${#options[@]} <= ${#keys} )) || common::die 'Too many devices for the menu. Use --device.'
    for (( index=0; index<${#options[@]}; index++ )); do
        common::detail "${keys:index:1}) ${options[index]}" >&2
    done
    common::detail 'q) Quit' >&2
    while true; do
        if ! IFS= read -r -s -n 1 -p 'Choice: ' choice; then
            printf '\n' >&2
            return 1
        fi
        printf '\n' >&2
        [[ "$choice" != q && "$choice" != Q ]] || return 1
        for (( index=0; index<${#options[@]}; index++ )); do
            if [[ "$choice" == "${keys:index:1}" ]]; then
                printf '%s\n' "$((index + 1))"
                return 0
            fi
        done
        [[ -z "$choice" ]] || common::warn 'Choose one of the listed keys.'
    done
}

tpm::choose_device() {
    local devices argument choice
    local -a candidates=()

    devices="$(blkid -t TYPE=crypto_LUKS -o device || true)"
    while IFS= read -r argument; do
        [[ -z "$argument" ]] || candidates+=("$argument")
    done <<< "$devices"
    (( ${#candidates[@]} )) || common::die 'No LUKS devices found.'
    [[ -t 0 ]] || common::die 'Device selection needs a terminal; use --device.'
    common::step 'Choose the LUKS device to enroll:' >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS >&2
    choice="$(tpm::choose "${candidates[@]}")" || return 1
    printf '%s\n' "${candidates[choice - 1]}"
}

tpm::crypttab() {
    local file="$1" device="$2" uuid="$3"
    local line name source key options extra resolved option updated
    local matches=0
    local changed=false tpm_count=0
    local -a lines=() opts=()

    TPM_DEVICE=auto
    while IFS= read -r line || [[ -n "$line" ]]; do
        read -r name source key options extra <<< "$line"
        if [[ -z "$name" || "$name" == \#* ]]; then
            lines+=("$line")
            continue
        fi
        resolved=""
        if [[ "$source" == /dev/* ]]; then
            resolved="$(readlink -f -- "$source")"
        elif [[ "$source" == UUID=* || "$source" == LABEL=* || "$source" == PARTUUID=* || "$source" == PARTLABEL=* ]]; then
            resolved="$(blkid -t "$source" -o device || true)"
        fi
        if [[ "$source" != "UUID=$uuid" && "$resolved" != "$device" ]]; then
            lines+=("$line")
            continue
        fi
        matches=$((matches + 1))
        [[ -z "$extra" || "$extra" == \#* ]] || common::die 'Unexpected fields in the selected crypttab entry.'
        [[ "$key" == none || "$key" == - || -z "$key" ]] ||
            common::die 'The selected entry uses a key file; review its unlock policy manually first.'
        updated=""
        tpm_count=0
        IFS=, read -r -a opts <<< "$options"
        for option in "${opts[@]}"; do
            case "$option" in
                ''|-) continue ;;
                tpm2-device=*)
                    tpm_count=$((tpm_count + 1))
                    TPM_DEVICE="${option#*=}"
                    [[ "$TPM_DEVICE" == auto || "$TPM_DEVICE" =~ ^/dev/tpmrm[0-9]+$ ]] ||
                        common::die "Review the existing TPM device option before continuing: $option"
                ;;
                header=*) common::die 'Detached LUKS headers are not supported.' ;;
                plain|swap|tmp|tmp=*) common::die 'Refusing an entry configured as plain, swap, or temporary storage.' ;;
            esac
            updated+="${updated:+,}$option"
        done
        (( tpm_count <= 1 )) || common::die 'The selected crypttab entry has duplicate TPM device options.'
        if (( tpm_count == 1 )); then
            lines+=("$line")
        else
            changed=true
            updated+="${updated:+,}tpm2-device=auto"
            lines+=("$name $source ${key:-none} $updated${extra:+ $extra}")
        fi
    done < "$file"
    [[ "$matches" -eq 1 ]] ||
        common::die "Expected one existing crypttab entry for $device; found $matches. No entry was added or guessed."
    if [[ "$changed" == true ]]; then
        printf '%s\n' "${lines[@]}"
    else
        cat -- "$file"
    fi
}

tpm::install_packages() {
    local device_package package
    local install_dracut=false refreshed=false
    local -a packages=() missing=()

    if ! command -v dracut >/dev/null 2>&1; then
        install_dracut=true
        [[ -t 0 ]] || common::die 'Dracut is missing. Rerun in a terminal to review its installation.'
        common::warn 'Installing dracut can replace the current initramfs generator. Review the package-manager transaction.'
    fi
    if command -v apt-get >/dev/null 2>&1; then
        device_package="$(apt-cache pkgnames libtss2-tcti-device | LC_ALL=C sort | head -n 1)"
        if [[ -z "$device_package" ]]; then
            common::step 'Refreshing apt package lists...'
            apt-get update
            refreshed=true
            device_package="$(apt-cache pkgnames libtss2-tcti-device | LC_ALL=C sort | head -n 1)"
        fi
        [[ "$device_package" =~ ^libtss2-tcti-device[0-9]+(t64)?$ ]] ||
            common::die 'Could not resolve the Debian TPM2-TSS device transport package.'
        packages=(tpm2-tools "$device_package" cryptsetup)
        if ! command -v systemd-cryptenroll >/dev/null 2>&1 ||
            [[ ! -x /usr/lib/systemd/systemd-cryptsetup && ! -x /lib/systemd/systemd-cryptsetup ]]; then
            if apt-cache show systemd-cryptsetup >/dev/null 2>&1; then
                packages+=(systemd-cryptsetup)
            else
                packages+=(systemd)
            fi
        fi
        [[ "$install_dracut" == false ]] || packages+=(dracut)
        for package in "${packages[@]}"; do
            if [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" != 'install ok installed' ]]; then
                missing+=("$package")
            fi
        done
        if (( ${#missing[@]} )); then
            common::step "Installing missing packages: ${missing[*]}"
            [[ "$refreshed" == true ]] || apt-get update
            if [[ "$install_dracut" == true ]]; then
                apt-get install "${missing[@]}"
            else
                apt-get install -y "${missing[@]}"
            fi
        fi
    elif command -v dnf >/dev/null 2>&1; then
        packages=(tpm2-tss tpm2-tools cryptsetup systemd-cryptsetup)
        [[ "$install_dracut" == false ]] || packages+=(dracut)
        for package in "${packages[@]}"; do
            rpm -q "$package" >/dev/null 2>&1 || missing+=("$package")
        done
        if (( ${#missing[@]} )); then
            common::step "Installing missing packages: ${missing[*]}"
            if [[ "$install_dracut" == true ]]; then
                dnf install "${missing[@]}"
            else
                dnf install -y "${missing[@]}"
            fi
        fi
    else
        common::die 'Supported package managers: apt-get and dnf.'
    fi
    (( ${#missing[@]} )) || common::detail 'TPM dependencies are already installed.'
}

tpm::check_requirements() {
    local command_name modules module

    for command_name in dracut lsinitrd cryptsetup systemd-cryptenroll tpm2 \
        blkid lsblk readlink flock grep cmp cp mv install chmod mktemp uname; do
        command -v "$command_name" >/dev/null 2>&1 ||
            common::die "Missing required command: $command_name. Install it with your package manager, then rerun."
    done
    [[ -x /usr/lib/systemd/systemd-cryptsetup || -x /lib/systemd/systemd-cryptsetup ]] ||
        common::die 'The systemd-cryptsetup executable is missing.'
    compgen -G '/dev/tpmrm*' >/dev/null || common::die 'No TPM2 resource-manager device found. Check firmware TPM settings.'
    systemd-cryptenroll --tpm2-device=list
    modules="$(dracut --list-modules)"
    for module in systemd crypt tpm2-tss; do
        grep -qxE "[[:space:]]*$module[[:space:]]*" <<< "$modules" ||
            common::die "Missing dracut module: $module. Install your distribution's dracut modules, then rerun."
    done
    DRACUT_MODULES='systemd crypt tpm2-tss'
    if grep -qxE '[[:space:]]*systemd-cryptsetup[[:space:]]*' <<< "$modules"; then
        DRACUT_MODULES='systemd crypt systemd-cryptsetup tpm2-tss'
    fi
    common::detail 'Verified TPM tools, systemd-cryptsetup, and required dracut modules'
}

tpm::initramfs_ready() (
    local device="$1" uuid="$2"
    local expected_tpm="$TPM_DEVICE"
    local modules module

    modules="$(lsinitrd -m -k "$(uname -r)" 2>/dev/null)" || return 1
    for module in systemd crypt tpm2-tss; do
        grep -qxE "[[:space:]]*$module[[:space:]]*" <<< "$modules" || return 1
    done
    lsinitrd -k "$(uname -r)" -f etc/crypttab > "$TEMP_DIR/initramfs.crypttab" 2>/dev/null || return 1
    tpm::crypttab "$TEMP_DIR/initramfs.crypttab" "$device" "$uuid" > "$TEMP_DIR/initramfs.expected" 2>/dev/null || return 1
    cmp -s "$TEMP_DIR/initramfs.crypttab" "$TEMP_DIR/initramfs.expected" || return 1
    [[ "$TPM_DEVICE" == "$expected_tpm" ]] || return 1
    return 0
)

main() {
    local device="" choice=""
    local argument uuid metadata backup
    local config=/etc/dracut.conf.d/90-dotfiles-tpm.conf
    local policy='with the systemd default PCR policy'
    local -a enroll_options=()
    local enroll=true

    while (( $# )); do
        argument="$1"
        case "$argument" in
            --device)
                (( $# >= 2 )) || common::die '--device requires a path.'
                [[ -z "$device" ]] || common::die '--device was supplied twice.'
                device="$2"
                shift 2
            ;;
            --pcr7)
                enroll_options+=(--tpm2-pcrs=7)
                policy='with PCR 7'
                shift
            ;;
            -h|--help)
                tpm::usage
                return 0
            ;;
            *) common::die "Unknown argument: $argument" ;;
        esac
    done
    [[ "$(uname -s)" == Linux ]] || common::die 'This script currently supports Linux only.'
    [[ "$EUID" -eq 0 ]] || common::die 'Run this system setup script with sudo.'
    [[ -f /etc/crypttab && ! -L /etc/crypttab ]] || common::die 'Expected a regular /etc/crypttab file.'
    for argument in blkid readlink flock; do
        command -v "$argument" >/dev/null 2>&1 || common::die "Missing required command: $argument"
    done
    exec 9>/run/lock/dotfiles-setup-tpm.lock
    flock -n 9 || common::die 'Another TPM setup is running.'

    common::step 'Checking system dependencies...'
    tpm::install_packages
    common::step 'Checking TPM and dracut support...'
    tpm::check_requirements
    if [[ -z "$device" ]]; then
        device="$(tpm::choose_device)" || common::die 'Device selection cancelled.'
    fi
    device="$(readlink -f -- "$device")"
    [[ -b "$device" ]] || common::die "Not a block device: $device"
    cryptsetup isLuks --type luks2 "$device" || common::die 'The selected device must use LUKS2.'
    uuid="$(cryptsetup luksUUID "$device")"
    common::step "Selected $device (LUKS UUID $uuid)"
    umask 077
    TEMP_DIR="$(mktemp -d /etc/.dotfiles-tpm.XXXXXXXX)"
    trap tpm::cleanup EXIT
    cp -a /etc/crypttab "$TEMP_DIR/crypttab.original"
    tpm::crypttab "$TEMP_DIR/crypttab.original" "$device" "$uuid" > "$TEMP_DIR/crypttab"
    if cmp -s /etc/crypttab "$TEMP_DIR/crypttab"; then
        common::detail "The existing crypttab entry already uses TPM device $TPM_DEVICE."
    else
        common::detail 'The existing crypttab entry needs a TPM device option.'
    fi
    if tpm::initramfs_ready "$device" "$uuid"; then
        common::detail 'The running kernel initramfs already includes TPM modules and a TPM crypttab entry'
    else
        common::warn 'Could not verify TPM boot configuration in the running kernel initramfs. Repair will rebuild it.'
    fi
    metadata="$(LC_ALL=C SYSTEMD_COLORS=0 systemd-cryptenroll "$device")"
    if grep -qE '^[[:space:]]*[0-9]+[[:space:]]+tpm2[[:space:]]*$' <<< "$metadata"; then
        enroll=false
        common::detail 'This device already has a TPM enrollment.'
        common::detail "$metadata"
        if [[ -t 0 ]]; then
            choice="$(tpm::choose 'Keep current setup' 'Keep enrollment and repair boot configuration' "Replace TPM enrollment $policy")" ||
                common::die 'Setup cancelled.'
            case "$choice" in
                1)
                    common::summary 'Existing TPM enrollment, crypttab, and dracut settings preserved'
                    return 0
                ;;
                2) ;;
                3)
                    enroll=true
                    enroll_options+=(--wipe-slot=tpm2)
                ;;
            esac
        else
            common::summary 'Existing setup preserved. Rerun in a terminal to repair or replace it.'
            return 0
        fi
    fi
    [[ ! -L "$config" ]] || common::die "Refusing a symlink: $config"
    if [[ -e "$config" ]]; then
        case "$(<"$config")" in
            'add_dracutmodules+=" systemd crypt tpm2-tss "'|\
            'add_dracutmodules+=" systemd crypt systemd-cryptsetup tpm2-tss "') ;;
            *) common::die "Refusing to overwrite unmanaged $config" ;;
        esac
    fi
    common::step 'Backing up the current configuration...'
    cmp -s /etc/crypttab "$TEMP_DIR/crypttab.original" ||
        common::die 'Crypttab changed during setup. Rerun to inspect the current configuration.'
    backup="$(mktemp -d /root/tpm-setup-backup.XXXXXXXX)"
    cp -a /etc/crypttab "$backup/crypttab"
    [[ ! -e "$config" ]] || cp -a "$config" "$backup/dracut.conf"
    cryptsetup luksHeaderBackup "$device" --header-backup-file "$backup/luks-header.img"
    common::detail "Configuration and LUKS header backups: $backup"
    if [[ "$enroll" == false ]]; then
        common::detail 'Existing TPM enrollment retained, including its PCR/PIN policy.'
    else
        common::step "Enrolling TPM2 $policy..."
        systemd-cryptenroll "--tpm2-device=$TPM_DEVICE" "${enroll_options[@]}" "$device"
    fi
    cmp -s /etc/crypttab "$TEMP_DIR/crypttab.original" ||
        common::die "Crypttab changed during enrollment. Boot configuration was not written. Backups: $backup"
    if ! cmp -s /etc/crypttab "$TEMP_DIR/crypttab"; then
        common::step 'Updating the selected crypttab entry...'
        cp -a /etc/crypttab "$TEMP_DIR/crypttab.new"
        cat "$TEMP_DIR/crypttab" > "$TEMP_DIR/crypttab.new"
        mv -f -- "$TEMP_DIR/crypttab.new" /etc/crypttab
    fi
    install -d -m 0755 /etc/dracut.conf.d
    printf 'add_dracutmodules+=" %s "\n' "$DRACUT_MODULES" > "$TEMP_DIR/dracut.conf"
    if ! cmp -s "$TEMP_DIR/dracut.conf" "$config"; then
        common::step 'Configuring dracut TPM support...'
        chmod 0644 "$TEMP_DIR/dracut.conf"
        mv -f -- "$TEMP_DIR/dracut.conf" "$config"
    fi
    common::step 'Regenerating dracut images for all installed kernels...'
    if ! dracut --regenerate-all --force; then
        common::die "Dracut failed. Configuration/enrollment remain in place; fix and rerun before rebooting. Backups: $backup"
    fi
    common::step 'Verifying the rebuilt initramfs...'
    if ! tpm::initramfs_ready "$device" "$uuid"; then
        common::die "Could not verify TPM modules and crypttab in the running kernel initramfs. Check dracut configuration before rebooting. Backups: $backup"
    fi
    common::step 'Caveats'
    common::detail 'Keep your working LUKS passphrase/recovery key and verify unlocking on the next reboot.'
    common::summary "TPM setup complete for $device"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
