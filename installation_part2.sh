#!/usr/bin/env bash


MODE="${1}"
DISK="${2}"
LOG_FILE="$(basename "${0}")"
LOG_FILE="${LOG_FILE}.log"

# Logging the entire script
exec 3>&1 4>&2 > >(tee -a "${LOG_FILE}") 2>&1

# Sourcing log functions
if source log_functions.sh; then
    log_info "sourced log_functions.sh"
else
    echo "Error! Could not source log_functions.sh"
    exit 1
fi

# Checking the argument MODE
if [[ "${MODE}" == "BIOS" || "${MODE}" != "UEFI" ]]; then
    log_error "Check the first argument! ${MODE} was provided"
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
	pacman --noconfirm --sync --refresh archlinux-keyring
    log_ok "DONE"
}

# Setting up time
function set_time(){
    log_info "Setting up time"

    ln --symbolic --force /usr/share/zoneinfo/Europe/Bucharest /etc/localtime
    # system-to-hardwareclock
    hwclock --systohc

    log_ok "DONE"
}

# Changing the language to english
function change_language(){
    log_info "Setting up language"

    sed --in-place "s|#en_US.UTF-8 UTF-8|en_US.UTF-8 UTF-8|g" /etc/locale.gen
	echo "LANG=en_US.UTF-8" > /etc/locale.conf
	locale-gen

    log_ok "DONE"
}

# Setting the hostname
function set_hostname(){
    log_info "Setting hostname to archlinux"

	echo "archlinux" > /etc/hostname

    log_ok "DONE"
}

# Change root password
function change_root_password() {
    log_info "Change root password"

    while ! passwd ; do
        sleep 1
    done

    log_ok "DONE"
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
	useradd --create-home --groups wheel --shell /bin/bash "${NAME}"

    log_info "Adding wheel to sudoers"
    echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/01-wheel_group

    log_info "Setting up user password"
    while ! passwd "${NAME}"; do
        sleep 1
    done

    log_ok "DONE"
}

# Installing grub and creating configuration
function grub_configuration() {
    log_info "Installing and configuring grub"
	if [[ "${MODE}" == "UEFI" ]]; then
        pacman --noconfirm --sync grub efibootmgr
        grub-install --target=x86_64-efi --efi-directory=/boot
		grub-mkconfig --output=/boot/grub/grub.cfg
	elif [[ "${MODE}" == "BIOS" ]]; then
        pacman --noconfirm --sync grub
		grub-install /dev/"${DISK}"
		grub-mkconfig --output=/boot/grub/grub.cfg
	else
		log_error "An error occured at grub step. Exiting..."
	fi

    log_ok "DONE"
}

# Enabling services
function enable_services(){

    log_info "Enabling NetworkManager, earlyoom and sshd"
    systemctl enable NetworkManager
    systemctl enable sshd
    log_ok "DONE"
}


# MAIN
function main(){
    configuring_pacman
    set_time
	change_language
	set_hostname
    change_root_password
	set_user
    grub_configuration
    enable_services

    log_ok "DONE"
    log_info "Exit the chroot now 'exit' and reboot"
    log_warning "Don't forget to take out the installation media"
    exec 1>&3 2>&4
}

main
