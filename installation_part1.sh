#!/usr/bin/env bash

LOG_FILE="$(basename "${0}")"
LOG_FILE="${LOG_FILE}.log"

# Logging the entire script
exec 3>&1 4>&2 > >(tee --append "${LOG_FILE}") 2>&1


if ! source ./log_functions.sh; then
    echo "Error! Could not source log_functions.sh"
    exit 1
fi

# Check for internet
function check_internet() {
    log_info "Check Internet"
	if ! ping -c1 -w1 8.8.8.8 > /dev/null 2>&1; then
        log_info "Visit https://wiki.arch.org/wiki/Handbook:AMD64/Installation/Networking"
        log_info "Optionally use 'links https://wiki.arch.org/wiki/Handbook:AMD64/Installation/Networking'"
        log_error "No Internet Connection"
    else
        log_ok "Connected to internet"
	fi
}

# Initializing keys and setting pacman
function configuring_pacman(){
    log_info "Configuring pacman"

    CORES="$(nproc)"
    ((CORES -= 1))

    CONF_FILE="/etc/pacman.conf"

    sed --regexp-extended --in-place "s|^#ParallelDownloads.*|ParallelDownloads = ${CORES}|g" "${CONF_FILE}" 
    log_ok "DONE"

    log_info "Installing the keyring"
	pacman --noconfirm --sync --refresh archlinux-keyring || log_error "Aborting..."
    log_ok "DONE"
}

# Selecting the disk to install on
function disks() {
    log_info "Select installation disk"

    DISK="$(lsblk --bytes --nodeps --noheadings --exclude 7 | sort --numeric-sort --key=5 --reverse | awk '{print $1; exit}')"
    ANSWER=""

    log_warning "From this point there is no going back! Proceed with caution."
    log_info "Disk chosen: ${DISK}"

    while [[ "${ANSWER}" != 'yes' && "${ANSWER}" != 'no' ]]; do
        printf "Select disk for installation (yes/no): "
        read -r ANSWER
    done

    if [[ "${ANSWER}" == 'no' ]]; then
        # TODO: create arguments for this script
        log_error "Please pass the desired disk with the argument..."
    fi

    log_ok "DONE"
}

# Creating partitions
function partitioning() {
    log_info "Partitioning disk"
    log_info "Wiping the data on disk ${DISK}"

    wipefs --all "/dev/${DISK}" || log_error "Could not wipe disk ${DISK}. Aborting..."

    if [[ -n $(ls /sys/firmware/efi/efivars 2>/dev/null) ]];then
        MODE="UEFI"
        # Make a GPT partitioning type - compatible with UEFI
        parted --script /dev/"${DISK}" mklabel gpt

        # Boot
        parted --script /dev/"${DISK}" mkpart fat32 2048s 1GiB
        parted --script /dev/"${DISK}" set 1 esp on

        # Swap
        parted --script /dev/"${DISK}" mkpart linux-swap 1GiB 5GiB

        # Root
        parted --script /dev/"${DISK}" mkpart ext4 5GiB 35GiB

        # Home
        parted --script /dev/"${DISK}" mkpart ext4 35GiB 100%

        # Partitions allignment
        parted --script /dev/"${DISK}" align-check optimal 1 
    else
        MODE="BIOS"
        # Make a MBR partitioning type - compatible with BIOS
        parted --script /dev/"${DISK}" mklabel msdos

        # Boot and Root
        parted --script /dev/"${DISK}" mkpart primary ext4 2048s 35GiB

        # Swap
        parted --script /dev/"${DISK}" mkpart primary linux-swap 35GiB 39GiB

        # Home
        parted --script /dev/"${DISK}" mkpart primary ext4 39GiB 100%

        # Partitions allignment
        parted --script /dev/"${DISK}" align-check optimal 1 
    fi

    log_ok "DONE"
}


# Formatting partitions
function formatting() {
    log_info "Formatting partitions"

    PARTITIONS="$(blkid --output device | grep "${DISK}" | sort)"

    if [[ "${MODE}" == "UEFI" ]]; then
        BOOT_P="$(echo "${PARTITIONS}" | sed -n '1p')"
        # Fat32 filesystem
        mkfs.vfat -F32 "${BOOT_P}"

        SWAP_P="$(echo "${PARTITIONS}" | sed -n '2p')"
        ROOT_P="$(echo "${PARTITIONS}" | sed -n '3p')"
        HOME_P="$(echo "${PARTITIONS}" | sed -n '4p')"
    elif [[ "${MODE}" == "BIOS" ]]; then 
        ROOT_P=$(echo "${PARTITIONS}" | sed -n '1p')
        SWAP_P=$(echo "${PARTITIONS}" | sed -n '2p')
        HOME_P=$(echo "${PARTITIONS}" | sed -n '3p')
    fi

    mkswap "${SWAP_P}" && swapon "${SWAP_P}" && mkfs.ext4 -F "${HOME_P}" && mkfs.ext4 -F "${ROOT_P}" || log_error "Aborting..."

    log_ok "DONE"
}

# Mounting partitons
function mounting() {
    log_info "Mounting partitions"

    mkdir --parents /mnt
    mount "${ROOT_P}" /mnt

    mkdir --parents /mnt/home
    mount "${HOME_P}" /mnt/home

    [[ "${MODE}" == "UEFI" ]] && \
        mkdir --parents /mnt/boot && \
        mount "${BOOT_P}" /mnt/boot

    log_ok "DONE"
}

# Installing packages
function install_packages(){
    log_info "Installing packages on the new system"

    # shellcheck disable=SC2046
	pacstrap -K /mnt $(tail packages.csv -n +2 | awk -F ',' '{print $1}' | paste -sd' ')

    log_ok "DONE"
}

# Generating fstab
function generate_fstab(){
    log_info "Generating fstab"

    genfstab -U /mnt >> /mnt/etc/fstab

    log_ok "DONE"
}

# Enter the new environment
function enter_environment() {
    log_info "Copying the second installation part to new environment"

    chmod +x installation_part2.sh
    cp -a installation_part2.sh /mnt
    cp -a log_functions.sh /mnt

    log_ok "DONE"

    log_info "Entering the new environment"
    exec 1>&3 2>&4

    # shellcheck disable=SC2016
    arch-chroot /mnt /bin/bash "/installation_part2.sh" "'${MODE}'" "'${DISK}'"
}

# MAIN
function main() {
	check_internet
	configuring_pacman
	disks
	partitioning
	formatting
	mounting
	install_packages
    generate_fstab
    enter_environment

    log_info "Rebooting..."
    sleep 3
    reboot
}

main
