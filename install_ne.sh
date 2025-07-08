#!/usr/bin/env bash

# ==============================================================================
# Node Exporter Installer & Uninstaller
#
# This script installs or removes the Prometheus Node Exporter. The removal
# process intelligently checks the service file to find and prompt for removal
# of the correct user, group, and firewall port.
#
# Usage:
#   sudo ./instal_ne.sh                (Defaults to --install)
#   sudo ./instal_ne.sh --install --user custom --port 9900
#   sudo ./instal_ne.sh --remove --user custom  (Will find port 9900 automatically)
#   ./instal_ne.sh --help
# ==============================================================================

# --- Strict Mode & Error Handling ---
set -euo pipefail

# --- Default Configuration Variables (can be overridden by arguments) ---
SERVICE_USER="node_exporter"
SERVICE_GROUP="node_exporter"
DATA_PORT="9100"

# --- Static Configuration Variables ---
readonly BINARY_PATH="/usr/local/bin/node_exporter"

# --- Dynamic Platform Variables (set at runtime) ---
PLATFORM_ARCH=""
SERVICE_FILE=""

# --- Color & Formatting Variables ---
readonly COLOR_GREEN=$(tput setaf 2)
readonly COLOR_YELLOW=$(tput setaf 3)
readonly COLOR_RED=$(tput setaf 1)
readonly COLOR_RESET=$(tput sgr0)
readonly BOLD=$(tput bold)

# --- Logging Functions ---
msg() {
    echo >&2 -e "${1-}"
}
success() {
    msg "${COLOR_GREEN}✅ ${BOLD}SUCCESS:${COLOR_RESET} ${1}"
}
notice() {
    msg "${COLOR_YELLOW}⚠️  ${BOLD}NOTICE:${COLOR_RESET} ${1}"
}
fatal() {
    msg "${COLOR_RED}❌ ${BOLD}FATAL:${COLOR_RESET} ${1}"
    exit 1
}

# --- SCRIPT SETUP ---
TMPDIR=$(mktemp -d)
trap 'msg "\n--- Cleaning up temporary files ---"; rm -rf "$TMPDIR"' EXIT

#==============================================================================
# --- HELPER FUNCTIONS ---
#==============================================================================

detect_platform_arch() {
    msg "--- Detecting platform architecture ---"
    local os
    local arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case "$os" in
        linux)
            if [[ "$arch" == "x86_64" ]]; then
                PLATFORM_ARCH="linux-amd64"
            else
                fatal "Unsupported Linux architecture: '${arch}'. This script currently only supports amd64 (x86_64) on Linux."
            fi
            ;;
        darwin)
            notice "Detected macOS (Darwin). This script's install/remove functions are for Linux (systemd) only."
            fatal "Platform 'macOS' detected, but installation is not supported."
            ;;
        *)
            fatal "Unsupported operating system: '${os}'."
            ;;
    esac
    success "Platform detected: ${PLATFORM_ARCH}"
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fatal "This script must be run as root or with sudo for install/remove operations."
    fi
}

check_dependencies() {
    msg "--- Checking for required packages ---"
    local missing_packages=()
    local dependencies=("curl" "tar" "jq" "grep" "sed" "wget")

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_packages+=("$dep")
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        notice "Missing required packages: ${missing_packages[*]}"
        
        local pm
        local install_cmd
        if command -v apt-get &>/dev/null; then
            pm="apt"
            install_cmd="sudo apt-get install -y"
        elif command -v dnf &>/dev/null; then
            pm="dnf"
            install_cmd="sudo dnf install -y"
        elif command -v yum &>/dev/null; then
            pm="yum"
            install_cmd="sudo yum install -y"
        else
            fatal "Could not find a supported package manager (apt, dnf, yum). Please install the missing packages manually."
        fi

        read -p "Do you want to try and install them now using ${pm}? (y/N) " -n 1 -r REPLY
        echo
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            msg "--- Attempting to install missing packages... ---"
            if ! $install_cmd "${missing_packages[@]}"; then
                 fatal "Failed to install dependencies. Please install them manually and rerun the script."
            fi
            success "Dependencies reinstalled successfully."
        else
            fatal "User declined to install dependencies. Exiting."
        fi
    fi
}

setup_user_and_group() {
    msg "--- Creating user '${SERVICE_USER}' and group '${SERVICE_GROUP}' ---"
    if ! getent group "$SERVICE_GROUP" >/dev/null; then
        groupadd --system "$SERVICE_GROUP"
    fi
    if ! getent passwd "$SERVICE_USER" >/dev/null; then
        useradd --system \
            -d /var/lib/node_exporter -s /bin/false \
            -g "$SERVICE_GROUP" "$SERVICE_USER"
    fi
}

download_and_install_binary() {
    msg "--- Downloading and installing Node Exporter for ${PLATFORM_ARCH} ---"
    cd "$TMPDIR"
    local latest_url
    latest_url=$(curl -s "https://api.github.com/repos/prometheus/node_exporter/releases/latest" | jq -r ".assets[] | select(.name | contains(\"${PLATFORM_ARCH}.tar.gz\")) | .browser_download_url")

    if [[ -z "$latest_url" ]]; then
        fatal "Could not automatically find the download URL for platform '${PLATFORM_ARCH}'."
    fi

    msg "--- Latest version found: ${latest_url} ---"
    wget -q --show-progress "$latest_url"
    local tar_file
    tar_file=$(basename "$latest_url")
    tar -xf "$tar_file"
    local extracted_dir
    extracted_dir=${tar_file%.tar.gz}

    install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0755 "${extracted_dir}/node_exporter" "${BINARY_PATH}"
}

create_systemd_service() {
    msg "--- Creating systemd service file: ${SERVICE_FILE} ---"
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Prometheus Node Exporter (user: ${SERVICE_USER})
Wants=network-online.target
After=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
Type=simple
ExecStart=${BINARY_PATH} --web.listen-address=:${DATA_PORT}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

setup_firewall() {
    msg "--- Configuring firewall ---"
    if systemctl is-active --quiet firewalld; then
        msg "--- firewalld is active. Opening port ${DATA_PORT}/tcp ---"
        firewall-cmd --permanent --add-port="${DATA_PORT}/tcp" --quiet
        firewall-cmd --reload
    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        msg "--- ufw is active. Opening port ${DATA_PORT}/tcp ---"
        ufw allow "${DATA_PORT}/tcp" >/dev/null
    else
        notice "No active firewall (firewalld/ufw) detected. Skipping port configuration."
    fi
}

#==============================================================================
# --- MAIN LOGIC FUNCTIONS ---
#==============================================================================

install_node_exporter() {
    msg "\n${BOLD}Starting Node Exporter Installation...${COLOR_RESET}"
    check_root
    check_dependencies

    # Use the remove function for a clean slate, which is now intelligent
    if command -v "$BINARY_PATH" &>/dev/null || [[ -f "$SERVICE_FILE" ]]; then
        notice "Previous installation detected. Running a clean removal first."
        remove_node_exporter
        msg "\n--- Continuing with new installation ---"
    fi

    setup_user_and_group
    download_and_install_binary
    create_systemd_service

    systemctl daemon-reload
    setup_firewall

    msg "--- Enabling and starting Node Exporter service ---"
    systemctl enable --now "$(basename "$SERVICE_FILE" .service)"

    success "Node Exporter has been installed and started!"
    msg "--- To check status: ${BOLD}sudo systemctl status $(basename "$SERVICE_FILE" .service)${COLOR_RESET} ---"
    msg "--- Metrics endpoint: ${BOLD}http://<your_server_ip>:${DATA_PORT}/metrics${COLOR_RESET} ---"
}

remove_node_exporter() {
    msg "\n${BOLD}Starting Node Exporter Removal...${COLOR_RESET}"
    check_root

    local user_to_remove="$SERVICE_USER"
    local group_to_remove="$SERVICE_GROUP"
    local port_to_remove="$DATA_PORT" # Initialize with default/passed-in value
    local service_name
    service_name=$(basename "$SERVICE_FILE" .service)
    
    # Intelligently find the user, group, and port from the service file if it exists
    if [[ -f "$SERVICE_FILE" ]]; then
        msg "--- Reading configuration from service file: $SERVICE_FILE ---"
        # Extract user, group, and port, ignoring whitespace and comments
        local found_user
        found_user=$(grep -E '^\s*User\s*=' "$SERVICE_FILE" | sed 's/.*=//' | tr -d '[:space:]')
        local found_group
        found_group=$(grep -E '^\s*Group\s*=' "$SERVICE_FILE" | sed 's/.*=//' | tr -d '[:space:]')
        local found_port
        found_port=$(grep -E '^\s*ExecStart\s*=' "$SERVICE_FILE" | sed -n 's/.*--web.listen-address=:\([0-9]\+\).*/\1/p')

        [[ -n "$found_user" ]] && user_to_remove="$found_user"
        [[ -n "$found_group" ]] && group_to_remove="$found_group"

        if [[ -n "$found_port" ]]; then
            port_to_remove="$found_port"
            success "Detected port ${port_to_remove} from service file."
        fi
    else
        notice "Service file ${SERVICE_FILE} not found. Using specified user/group/port for removal."
    fi

    msg "--- Stopping and disabling service '${service_name}' ---"
    systemctl stop "$service_name" &>/dev/null || true
    systemctl disable "$service_name" &>/dev/null || true

    # Remove firewall rule using the detected (or default) port
    if systemctl is-active --quiet firewalld; then
        msg "--- Removing firewalld rule for port ${port_to_remove}/tcp ---"
        firewall-cmd --permanent --remove-port=${port_to_remove}/tcp --quiet || true
        firewall-cmd --reload
    elif command -v ufw &>/dev/null; then
        msg "--- Removing ufw rule for port ${port_to_remove}/tcp ---"
        ufw delete allow ${port_to_remove}/tcp >/dev/null || true
    fi

    msg "--- Removing service file and binary ---"
    rm -f "$SERVICE_FILE" "$BINARY_PATH"
    systemctl daemon-reload

    # Prompt before removing user
    if getent passwd "$user_to_remove" >/dev/null; then
        local reply_user
        read -p "Do you want to remove the user '${user_to_remove}'? (y/N) " -n 1 -r reply_user
        echo
        if [[ "$reply_user" =~ ^[Yy]$ ]]; then
            if userdel "$user_to_remove"; then
                success "User '${user_to_remove}' removed."
            else
                notice "Could not remove user '${user_to_remove}'. It might be in use."
            fi
        fi
    fi

    # Prompt before removing group
    if getent group "$group_to_remove" >/dev/null; then
        local reply_group
        read -p "Do you want to remove the group '${group_to_remove}'? (y/N) " -n 1 -r reply_group
        echo
        if [[ "$reply_group" =~ ^[Yy]$ ]]; then
            if groupdel "$group_to_remove"; then
                success "Group '${group_to_remove}' removed."
            else
                notice "Could not remove group '${group_to_remove}'. It might have other members."
            fi
        fi
    fi
    
    success "Node Exporter removal process finished."
}

show_help() {
    cat <<EOF
${BOLD}Node Exporter Management Script${COLOR_RESET}

This script installs or removes the Prometheus Node Exporter on Linux systems.
If run without any arguments, it defaults to the --install action.

${BOLD}USAGE:${COLOR_RESET}
  sudo $0 [command] [options]

${BOLD}COMMANDS:${COLOR_RESET}
  --install              Installs and starts the Node Exporter service. (Default)
  --remove               Stops and completely removes the Node Exporter.
  --help                 Displays this help message.

${BOLD}OPTIONS:${COLOR_RESET}
  --user <name>          Set the service user. Defaults to 'node_exporter'.
  --group <name>         Set the service group. Defaults to 'node_exporter'.
  --port <number>        Set the data port. Defaults to '9100'.

${BOLD}EXAMPLES:${COLOR_RESET}
  sudo $0
  sudo $0 --install --port 9900 --user web_metrics
  sudo $0 --remove --user web_metrics

EOF
}

#==============================================================================
# --- SCRIPT ENTRYPOINT ---
#==============================================================================
main() {
    detect_platform_arch
    local action=""

    if [[ $# -eq 0 ]]; then
        notice "No arguments specified. Defaulting to --install."
        action="--install"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install|--remove)
                [[ -n "$action" ]] && fatal "Only one action (--install or --remove) can be specified."
                action="$1"
                shift
                ;;
            --user)
                [[ -z "${2-}" ]] && fatal "Argument missing for --user."
                SERVICE_USER="$2"
                shift 2
                ;;
            --group)
                [[ -z "${2-}" ]] && fatal "Argument missing for --group."
                SERVICE_GROUP="$2"
                shift 2
                ;;
            --port)
                [[ -z "${2-}" ]] && fatal "Argument missing for --port."
                DATA_PORT="$2"
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                fatal "Invalid argument: $1. Use --help to see available options."
                ;;
        esac
    done

    SERVICE_FILE="/etc/systemd/system/${SERVICE_USER}.service"

    case "$action" in
        --install)
            install_node_exporter
            ;;
        --remove)
            remove_node_exporter
            ;;
        *)
            fatal "No action specified. Please use --install or --remove. Use --help for more details."
            ;;
    esac
}

main "$@"
