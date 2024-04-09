#!/usr/bin/env bash
# shellcheck disable=1090

TEMP_DIR="$(dirname "${0}")"
SCRIPT_NAME="$(basename "${0}")"
LOG_FILE="${SCRIPT_NAME}.log"
PASSED_ENV_VARS=".installation_part2.env"
FUNCTIONS="functions.sh"
CONFIG_FILE="installation_config.sh"

MODE="${1}"
DISK="${2}"

# Logging the entire script
exec 3>&1 4>&2 > >(tee -a "${LOG_FILE}") 2>&1

pushd "${TEMP_DIR}" || exit 1

# Sourcing log functions
if ! source "${FUNCTIONS}"; then
    echo "Error! Could not source ${FUNCTIONS}"
    exit 1
fi

# Sourcing configuration file
if ! source "${CONFIG_FILE}"; then
    echo "Error! Could not source ${CONFIG_FILE}"
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

    log_info "Refreshing sources"
	exit_on_error pacman --noconfirm --sync --refresh
    log_ok "DONE"

    log_info "Initializing key"
	exit_on_error pacman-key --init
    log_ok "DONE"

    log_info "Refreshing keys"
	exit_on_error pacman-key --refresh-keys
    log_ok "DONE"

    log_info "Installing the keyring"
	exit_on_error pacman --noconfirm --sync --refresh archlinux-keyring
    log_ok "DONE"

    echo PASSED_CONFIGURING_PACMAN="PASSED" >> "${PASSED_ENV_VARS}"
}

# Setting up time
function set_time(){
    log_info "Setting up time"

    exit_on_error ln --symbolic --force "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime && \
        hwclock --systohc

    log_ok "DONE"

    echo PASSED_SET_TIME="PASSED" >> "${PASSED_ENV_VARS}"
}

# Changing the language to english
function change_language(){
    log_info "Setting up language"

    sed --in-place "/${LANG}/s|^#||" /etc/locale.gen
    echo "LANG=${LANG}" > /etc/locale.conf
    locale-gen

    log_ok "DONE"

    echo PASSED_CHANGE_LANGUAGE="PASSED" >> "${PASSED_ENV_VARS}"
}

# Setting the hostname
function set_hostname(){
    log_info "Setting hostname to archlinux"

	echo "${HOSTNAME}" > /etc/hostname

    log_ok "DONE"

    echo PASSED_SET_HOSTNAME="PASSED" >> "${PASSED_ENV_VARS}"
}

# Change root password
function change_root_password() {
    log_info "Change root password"

    while ! passwd ; do
        sleep 1
    done

    log_ok "DONE"

    echo PASSED_CHANGE_ROOT_PASSWORD="PASSED" >> "${PASSED_ENV_VARS}"
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

    echo PASSED_SET_USER="PASSED" >> "${PASSED_ENV_VARS}"
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

    echo PASSED_GRUB_CONFIGURATION="PASSED" >> "${PASSED_ENV_VARS}"
}

# Enabling services
function enable_services(){

    log_info "Enabling NetworkManager, earlyoom and sshd"
    exit_on_error systemctl enable NetworkManager && \
        systemctl enable sshd
    log_ok "DONE"

    echo PASSED_ENABLE_SERVICES="PASSED" >> "${PASSED_ENV_VARS}"
}

#Install yay: script taken from Luke Smith
function yay_install() {
    log_info "Installing yay - AUR package manager"

	sudo -u "${NAME}" mkdir -p "/home/${NAME}/.local/yay"
	exit_on_error sudo -u "${NAME}" git -C "/home/${NAME}/.local" clone --depth 1 --single-branch \
		--no-tags -q "https://aur.archlinux.org/yay.git" "/home/${NAME}/.local/yay" ||
		{
            pushd "/home/${NAME}/.local/yay" || exit 1
			exit_on_error sudo -u "${NAME}" git pull --force origin master
            popd || exit 1
		}

    pushd "/home/${NAME}/.local/yay" || exit 1
	exit_on_error sudo -u "${NAME}" makepkg --noconfirm -si || return 1
    popd || exit 1

    # shellcheck disable=2046
	exit_on_error sudo -u "${NAME}" yay --noconfirm -S $(awk -F ',' '/AUR/ {printf "%s ", $1}' "${DE}-packages.csv")

    log_ok "DONE"

    echo PASSED_YAY_INSTALL="PASSED" >> "${PASSED_ENV_VARS}"
}

function apply_configuration() {
    log_info "Downloading and applying new configuration"

	exit_on_error sudo -u "${NAME}" git -C "/home/${NAME}/" clone --depth 1 --single-branch \
		--no-tags -q "https://github.com/arghpy/dotfiles" "/home/${NAME}/"

    if ! [[ "${DE}" = "i3" ]]; then
        rm -rf "/home/${NAME}/.config/i3*"
        rm -f "/home/${NAME}/.xprofile"
    fi

    log_ok "DONE"

    echo PASSED_APPLY_CONFIGURATION="PASSED" >> "${PASSED_ENV_VARS}"
}

function install_additional_packages() {

    log_info "Installing additonal packages on the new system"

    # shellcheck disable=SC2046
	exit_on_error pacman --noconfirm --sync --refresh $(awk -F ',' '/repo/ {printf "%s ", $1}' "${DE}-packages.csv")

    log_ok "DONE"

    echo PASSED_INSTALL_ADDITONAL_PACKAGES="PASSED" >> "${PASSED_ENV_VARS}"
}

function configure_additional_packages() {
    log_info "Configuring additional packages"

    if [[ "${DE}" = "i3" ]]; then
       log_info "Configuring lightdm" 

       mkdir -p /etc/lightdm/lightdm.conf.d
       sed "s|user_account|${NAME}|g" 99-switch-monitor.conf > /etc/lightdm/lightdm.conf.d/99-switch-display.conf
       exit_on_error systemctl enable lightdm

       log_ok "DONE"
    fi

    log_ok "DONE"

    echo PASSED_CONFIGURE_ADDITONAL_PACKAGES="PASSED" >> "${PASSED_ENV_VARS}"
}



# MAIN
function main(){
    touch "${PASSED_ENV_VARS}"
    [ -z "${PASSED_CONFIGURING_PACMAN+x}" ] && configuring_pacman
    [ -z "${PASSED_SET_TIME+x}" ] && set_time
	[ -z "${PASSED_CHANGE_LANGUAGE+x}" ] && change_language
	[ -z "${PASSED_SET_HOSTNAME+x}" ] && set_hostname
    [ -z "${PASSED_CHANGE_ROOT_PASSWORD+x}" ] && change_root_password
	[ -z "${PASSED_SET_USER+x}" ] && set_user
    [ -z "${PASSED_GRUB_CONFIGURATION+x}" ] && grub_configuration
    [ -z "${PASSED_ENABLE_SERVICES+x}" ] && enable_services
    [ -z "${PASSED_YAY_INSTALL+x}" ] && yay_install
    [ -z "${PASSED_APPLY_CONFIGURATION+x}" ] && apply_configuration
    [ -z "${PASSED_INSTALL_ADDITIONAL_PACKAGES+x}" ] && install_additional_packages
    [ -z "${PASSED_CONFIGURE_ADDITIONAL_PACKAGES+x}" ] && configure_additional_packages

    log_ok "DONE"
    exec 1>&3 2>&4

    popd || exit 1
    rm -rf "${TEMP_DIR}"
}

main
