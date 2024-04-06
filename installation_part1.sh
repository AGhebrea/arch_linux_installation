#!/usr/bin/env bash

LOG_FILE="$(basename "${0}")"
LOG_FILE="${LOG_FILE}.log"

if [ -f .installation.env ]; then
    source .installation.env
fi

# Logging the entire script
exec 3>&1 4>&2 > >(tee --append "${LOG_FILE}") 2>&1


if ! source ./functions.sh; then
    echo "Error! Could not source functions.sh"
    exit 1
fi

# Check for internet
function check_internet() {
    log_info "Check Internet"
	if ! ping -c1 -w1 8.8.8.8 > /dev/null 2>&1; then
        log_info "Visit https://wiki.arch.org/wiki/Handbook:AMD64/Installation/Networking"
        log_info "Optionally use 'links https://wiki.arch.org/wiki/Handbook:AMD64/Installation/Networking'"
        log_error "No Internet Connection" && exit 1
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
	exit_on_error pacman --noconfirm --sync --refresh archlinux-keyring
    log_ok "DONE"

    echo PASSED_CONFIGURING_PACMAN="PASSED" >> .installation.env
}

# Selecting the disk to install on
function disks() {
    log_info "Select installation disk"

    DISK="$(lsblk --nodeps --noheadings --exclude 7 --output NAME,SIZE | sort --key=2 | awk '{print $1; exit}')"
    ANSWER=""

    log_warning "From this point there is no going back! Proceed with caution."
    log_info "Disk chosen: ${DISK}"

    while [[ "${ANSWER}" != 'yes' && "${ANSWER}" != 'no' ]]; do
        printf "Select disk for installation (yes/no): "
        read -r ANSWER
    done

    if [[ "${ANSWER}" == 'no' ]]; then
        log_error "Please pass the installation disk with the argument -d, --disk DISK"
        usage
        exit 1
    fi

    log_ok "DONE"
}

# Creating partitions
function partitioning() {
    log_info "Partitioning disk"
    log_info "Wiping the data on disk ${DISK}"

    exit_on_error wipefs --all "/dev/${DISK}"

    if [[ -n $(ls /sys/firmware/efi/efivars 2>/dev/null) ]];then
        MODE="UEFI"
        # Make a GPT partitioning type - compatible with UEFI
        exit_on_error parted --script "/dev/${DISK}" mklabel gpt && \
            parted --script "/dev/${DISK}" mkpart fat32 2048s 1GiB && \
            parted --script "/dev/${DISK}" set 1 esp on && \
            parted --script "/dev/${DISK}" mkpart linux-swap 1GiB 5GiB && \
            parted --script "/dev/${DISK}" mkpart ext4 5GiB 35GiB && \
            parted --script "/dev/${DISK}" mkpart ext4 35GiB 100% && \
            parted --script "/dev/${DISK}" align-check optimal 1 
    else
        MODE="BIOS"
        # Make a MBR partitioning type - compatible with BIOS
        exit_on_error parted --script "/dev/${DISK}" mklabel msdos && \
            parted --script "/dev/${DISK}" mkpart primary ext4 2048s 35GiB && \
            parted --script "/dev/${DISK}" mkpart primary linux-swap 35GiB 39GiB && \
            parted --script "/dev/${DISK}" mkpart primary ext4 39GiB 100% && \
            parted --script "/dev/${DISK}" align-check optimal 1 
    fi

    log_ok "DONE"

    echo PASSED_PARTITIONING="PASSED" >> .installation.env
}


# Formatting partitions
function formatting() {
    log_info "Formatting partitions"

    PARTITIONS="$(blkid --output device | grep "${DISK}" | sort)"

    if [[ "${MODE}" == "UEFI" ]]; then
        BOOT_P="$(echo "${PARTITIONS}" | sed -n '1p')"
        # Fat32 filesystem
        exit_on_error mkfs.vfat -F32 "${BOOT_P}"

        SWAP_P="$(echo "${PARTITIONS}" | sed -n '2p')"
        ROOT_P="$(echo "${PARTITIONS}" | sed -n '3p')"
        HOME_P="$(echo "${PARTITIONS}" | sed -n '4p')"
    elif [[ "${MODE}" == "BIOS" ]]; then 
        ROOT_P=$(echo "${PARTITIONS}" | sed -n '1p')
        SWAP_P=$(echo "${PARTITIONS}" | sed -n '2p')
        HOME_P=$(echo "${PARTITIONS}" | sed -n '3p')
    fi

    exit_on_error mkswap "${SWAP_P}" && \
        swapon "${SWAP_P}" && \
        mkfs.ext4 -F "${HOME_P}" && \
        mkfs.ext4 -F "${ROOT_P}"

    log_ok "DONE"

    echo PASSED_FORMATTING="PASSED" >> .installation.env
}

# Mounting partitons
function mounting() {
    log_info "Mounting partitions"

    exit_on_error mkdir --parents /mnt && \
        mount "${ROOT_P}" /mnt && \
        mkdir --parents /mnt/home && \
        mount "${HOME_P}" /mnt/home

    [[ "${MODE}" == "UEFI" ]] && \
        exit_on_error mkdir --parents /mnt/boot && \
            mount "${BOOT_P}" /mnt/boot

    log_ok "DONE"

    echo PASSED_MOUNTING="PASSED" >> .installation.env
}

# Installing packages
function install_packages(){
    log_info "Installing packages on the new system"

    # shellcheck disable=SC2046
	exit_on_error pacstrap -K /mnt $(tail packages.csv -n +2 | awk -F ',' '{print $1}' | paste -sd' ')

    log_ok "DONE"

    echo PASSED_INSTALL_PACKAGES="PASSED" >> .installation.env
}

# Generating fstab
function generate_fstab(){
    log_info "Generating fstab"

    exit_on_error genfstab -U /mnt >> /mnt/etc/fstab

    log_ok "DONE"

    echo PASSED_GENERATE_FSTAB="PASSED" >> .installation.env
}

# Enter the new environment
function enter_environment() {
    log_info "Copying the second installation part to new environment"

    exit_on_error chmod +x installation_part2.sh && \
        cp -a installation_part2.sh /mnt && \
        cp -a functions.sh /mnt && \
        cp -a log_functions.sh /mnt

    log_ok "DONE"

    log_info "Entering the new environment"
    exec 1>&3 2>&4

    # shellcheck disable=SC2016
    exit_on_error arch-chroot /mnt /bin/bash "/installation_part2.sh" "${MODE}" "${DISK}"
}

# MAIN
function main() {
    touch .installation.env
	check_internet
	[ -z "${PASSED_CONFIGURING_PACMAN+x}" ] && configuring_pacman

    # Check if variable DISK is set or not: https://stackoverflow.com/questions/3601515/how-to-check-if-a-variable-is-set-in-bash
	[ -z "${DISK+x}" ] && disks

    [ -z "${PASSED_PARTITIONING+x}" ] && partitioning
    [ -z "${PASSED_FORMATTING+x}" ] && formatting
    [ -z "${PASSED_MOUNTING+x}" ] && mounting
    [ -z "${PASSED_INSTALL_PACKAGES+x}" ] && install_packages
    [ -z "${PASSED_GENERATE_FSTAB+x}" ] && generate_fstab
    enter_environment

    log_info "Rebooting..."
    sleep 3
    reboot
}

function usage() {
    cat << EOF

Usage: ./$(basename "${0}") [OPTIONS [ARGS]]

DESCRIPTION:
    This is a bash script used for installing Arch Linux.
    Available installation types:
        - server
        - desktop:
            * i3 (DE)
            * Gnome (DE)
            * list_of_DEs

OPTIONS:
    -h, --help
        Show this help message

    -l, --list
        List available disks

    -d, --disk DISK
        Provide disk for installation
        Example:
        ./$(basename "${0}") --disk sda

EOF
}

# Gather options
while [[ ! $# -eq 0 ]]; do
    case "${1}" in
        -h | --help)
            usage
            exit 0
            ;;

        -l | --list)
            log_info "Listing disks"
            lsblk --nodeps --noheadings --exclude 7 --output NAME,SIZE
            log_ok "DONE"
            exit 0
            ;;

        -d | --disk)
            if [ -z "${2-}" ]; then
                usage
                exit 1
            fi
            shift
            DISK="${1}"

            if ! lsblk --nodeps --noheadings --output NAME,SIZE "/dev/${DISK}"; then
                log_error "Wrong disk choice: ${DISK}"
                log_info "List available disks with -l, --list"
                usage
                exit 1
            fi
            ;;

        *)
            echo "Invalid option: ${1}"
            usage
            exit 1
            ;;
    esac
    shift
done


main
