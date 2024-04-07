#!/usr/bin/env bash


MODE="${1}"
DISK="${2}"
SCRIPT_NAME="$(basename "${0}")"
LOG_FILE="${SCRIPT_NAME}.log"

# Logging the entire script
exec 3>&1 4>&2 > >(tee -a "${LOG_FILE}") 2>&1

# Sourcing log functions
if ! source ./functions.sh; then
    echo "Error! Could not source functions.sh"
    exit 1
fi

if [  -z "${MODE}" ] || [ -z "${DISK}" ]; then
    log_error "Variables are not set. MODE: ${MODE}, DISK: ${DISK}"
fi

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

# Setting up time
function set_time(){
    log_info "Setting up time"

    exit_on_error ln --symbolic --force /usr/share/zoneinfo/Europe/Bucharest /etc/localtime && \
        hwclock --systohc

    log_ok "DONE"

    echo PASSED_SET_TIME="PASSED" >> .installation.env
}

# Changing the language to english
function change_language(){
    log_info "Setting up language"

    sed --in-place "s|#en_US.UTF-8 UTF-8|en_US.UTF-8 UTF-8|g" /etc/locale.gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    locale-gen

    log_ok "DONE"

    echo PASSED_CHANGE_LANGUAGE="PASSED" >> .installation.env
}

# Setting the hostname
function set_hostname(){
    log_info "Setting hostname to archlinux"

	echo "archlinux" > /etc/hostname

    log_ok "DONE"

    echo PASSED_SET_HOSTNAME="PASSED" >> .installation.env
}

# Change root password
function change_root_password() {
    log_info "Change root password"

    while ! passwd ; do
        sleep 1
    done

    log_ok "DONE"

    echo PASSED_CHANGE_ROOT_PASSWORD="PASSED" >> .installation.env
}

# Set user and password
function set_user() {
    log_info "Setting user account"

    NAME=""

    while [ -z "${NAME}" ]; do
        printf "Enter name for the local user: "
        read -r NAME
    done

    log_info "Creating ${NAME} user and adding it to wheel group"
	exit_on_error useradd --create-home --groups wheel --shell /bin/bash "${NAME}"

    log_info "Adding wheel to sudoers"
    echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/01-wheel_group

    log_info "Setting up user password"
    while ! passwd "${NAME}"; do
        sleep 1
    done

    log_ok "DONE"

    echo PASSED_SET_USER="PASSED" >> .installation.env
}

# Installing grub and creating configuration
function grub_configuration() {
    log_info "Installing and configuring grub"
	if [[ "${MODE}" = "UEFI" ]]; then
        exit_on_error pacman --noconfirm --sync grub efibootmgr && \
            grub-install --target=x86_64-efi --efi-directory=/boot && \
            grub-mkconfig --output=/boot/grub/grub.cfg
	elif [[ "${MODE}" = "BIOS" ]]; then
        exit_on_error pacman --noconfirm --sync grub && \
            grub-install /dev/"${DISK}" && \
            grub-mkconfig --output=/boot/grub/grub.cfg
	else
		log_error "An error occured at grub step. Exiting..."
	fi

    log_ok "DONE"

    echo PASSED_GRUB_CONFIGURATION="PASSED" >> .installation.env
}

# Enabling services
function enable_services(){

    log_info "Enabling NetworkManager, earlyoom and sshd"
    exit_on_error systemctl enable NetworkManager && \
        systemctl enable sshd
    log_ok "DONE"

    echo PASSED_ENABLE_SERVICES="PASSED" >> .installation.env
}

# TODO: this configuration must be on top. Also, continue it
function extra_configuration() {
    exit_on_error source ./installation_config.sh

    if [ "${DESKTOP}" = "yes" ]; then

    fi
}


# MAIN
function main(){
    touch .installation.env
    [ -z "${PASSED_CONFIGURING_PACMAN+x}" ] && configuring_pacman
    [ -z "${PASSED_SET_TIME+x}" ] && set_time
	[ -z "${PASSED_CHANGE_LANGUAGE+x}" ] && change_language
	[ -z "${PASSED_SET_HOSTNAME+x}" ] && set_hostname
    [ -z "${PASSED_CHANGE_ROOT_PASSWORD+x}" ] && change_root_password
	[ -z "${PASSED_SET_USER+x}" ] && set_user
    [ -z "${PASSED_GRUB_CONFIGURATION+x}" ] && grub_configuration
    [ -z "${PASSED_ENABLE_SERVICES+x}" ] && enable_services

    log_ok "DONE"
    exec 1>&3 2>&4
}

main
