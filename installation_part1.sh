#!/usr/bin/env bash

LOG_FILE="$(basename "${0}")"
LOG_FILE="${LOG_FILE}.log"
PROGS_GIT="https://raw.githubusercontent.com/arghpy/arch_install/main/packages.csv"

# Logging the entire script
exec 3>&1 4>&2 > >(tee --append "${LOG_FILE}") 2>&1


if source ./log_functions.sh; then
    log_info "Sourced log_functions.sh"
else
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
	pacman --noconfirm --sync --refresh archlinux-keyring
    log_ok "DONE"
}

# Selecting the disk to install on
function disks() {
    log_info "Select installation disk"

    DISK="$(lsblk --nodeps --noheadings --exclude 7 --output NAME)"
    NUMBER_OF_DISKS="$(echo "${DISK}" | wc -l )"
    
    if [[ ${NUMBER_OF_DISKS} -gt 1 ]]; then
        # TODO: pass the disk as an argument in case there are multiple
        log_error "Too many disks ${DISK}. Pass the disk with..."
    fi

    log_ok "DONE"
}

# Creating partitions
function partitioning() {
    log_info "Partitioning disk"
    log_info "Wiping the data on disk ${DISK}"

    if ! wipefs --all "${DISK}"; then
        log_error "Could not wipe disk ${DISK}. Aborting..."
    fi

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
        mkfs.vfat -F32 /dev/"${BOOT_P}"

        SWAP_P="$(echo "${PARTITIONS}" | sed -n '2p')"
        ROOT_P="$(echo "${PARTITIONS}" | sed -n '3p')"
        HOME_P="$(echo "${PARTITIONS}" | sed -n '4p')"
    elif [[ "${MODE}" == "BIOS" ]]; then 
        ROOT_P=$(echo "${PARTITIONS}" | sed -n '1p')
        SWAP_P=$(echo "${PARTITIONS}" | sed -n '2p')
        HOME_P=$(echo "${PARTITIONS}" | sed -n '3p')
    fi

    mkswap /dev/"${SWAP_P}"
    swapon /dev/"${SWAP_P}"
    mkfs.ext4 -F /dev/"${HOME_P}"
    mkfs.ext4 -F /dev/"${ROOT_P}"

    log_ok "DONE"
}

# Mounting partitons
function mounting() {
    log_info "Mounting partitions"

    mkdir --parents /mnt
    mount /dev/"${ROOT_P}" /mnt

    mkdir --parents /mnt/home
    mount /dev/"${HOME_P}" /mnt/home

    [[ "${MODE}" == "UEFI" ]] && \
        mkdir --parents /mnt/boot && \
        mount /dev/"${BOOT_P}" /mnt/boot

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
    cp installation_part2.sh /mnt

    log_ok "DONE"

    log_info "Entering the new environment"
    log_info "Run the second part of the script: './installation_part2.sh ${MODE} ${DISK}'"
    exec 1>&3 2>&4

    # shellcheck disable=SC2016
    arch-chroot /mnt 'MODE="${MODE}"; DISK="${DISK}"; ./installation_part2.sh "${MODE}" "${DISK}"'
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
}

main