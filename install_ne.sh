#!/usr/bin/env bash

# ==============================================================================
# Node Exporter Installer & Uninstaller
#
# This script installs or removes the Prometheus Node Exporter. It automatically
# detects the platform architecture, prompts to install missing dependencies, and
# allows for customization of the user, group, and port.
#
# Usage:
#   sudo ./install_node_exporter.sh --install
#   sudo ./install_node_exporter.sh --install --port 9900 --user custom_user
#   sudo ./install_node_exporter.sh --remove
#   ./install_node_exporter.sh --help
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
            # The installation steps will fail on Darwin, but we detect it as requested.
            notice "Detected macOS (Darwin). This script's install/remove functions are for Linux (systemd) only."
            if [[ "$arch" == "x86_64" ]]; then
                PLATFORM_ARCH="darwin-amd64"
            elif [[ "$arch" == "arm64" ]]; then
                PLATFORM_ARCH="darwin-arm64"
            else
                fatal "Unsupported Darwin (macOS) architecture: '${arch}'."
            fi
            fatal "Platform '${PLATFORM_ARCH}' detected, but installation is not supported on macOS."
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
    local dependencies=("curl" "tar" "jq")

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
        echo # Move to a new line
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            msg "--- Attempting to install missing packages... ---"
            if ! $install_cmd "${missing_packages[@]}"; then
                 fatal "Failed to install dependencies. Please install them manually and rerun the script."
            fi
            success "Dependencies installed successfully."
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

    if command -v "$BINARY_PATH" &>/dev/null || [[ -f "$SERVICE_FILE" ]]; then
        notice "Previous installation detected. Removing it first."
        remove_node_exporter
        msg "\n--- Continuing with new installation ---"
    fi

    setup_user_and_group
    download_and_install_binary
    create_systemd_service

    systemctl daemon-reload
    setup_firewall

    msg "--- Enabling and starting Node Exporter service ---"
    systemctl enable --now "${SERVICE_USER}"

    success "Node Exporter has been installed and started!"
    msg "--- To check status: ${BOLD}sudo systemctl status ${SERVICE_USER}${COLOR_RESET} ---"
    msg "--- Metrics endpoint: ${BOLD}http://<your_server_ip>:${DATA_PORT}/metrics${COLOR_RESET} ---"
}

remove_node_exporter() {
    msg "\n${BOLD}Starting Node Exporter Removal...${COLOR_RESET}"
    check_root

    if [[ -f "$SERVICE_FILE" ]]; then
        msg "--- Stopping and disabling service (${SERVICE_USER}) ---"
        systemctl stop "${SERVICE_USER}" || true
        systemctl disable "${SERVICE_USER}" || true
    else
        notice "Service file ${SERVICE_FILE} not found. Skipping service stop."
    fi

    if systemctl is-active --quiet firewalld; then
        msg "--- Removing firewalld rule for port ${DATA_PORT}/tcp ---"
        firewall-cmd --permanent --remove-port=${DATA_PORT}/tcp --quiet || true
        firewall-cmd --reload
    elif command -v ufw &>/dev/null; then
        msg "--- Removing ufw rule for port ${DATA_PORT}/tcp ---"
        ufw delete allow ${DATA_PORT}/tcp >/dev/null || true
    fi

    msg "--- Removing files and user ---"
    rm -f "$SERVICE_FILE" "$BINARY_PATH"
    systemctl daemon-reload
    userdel "$SERVICE_USER" >/dev/null 2>&1 || true
    if [[ "$SERVICE_GROUP" == "$SERVICE_USER" ]]; then
       groupdel "$SERVICE_GROUP" >/dev/null 2>&1 || true
    fi

    success "Node Exporter has been completely removed."
}

show_help() {
    cat <<EOF
${BOLD}Node Exporter Management Script${COLOR_RESET}

This script installs or removes the Prometheus Node Exporter on Linux systems.
It automatically detects the platform architecture and prompts to install missing
dependencies.

${BOLD}USAGE:${COLOR_RESET}
  sudo $0 [command] [options]

${BOLD}COMMANDS:${COLOR_RESET}
  --install              Installs and starts the Node Exporter service.
  --remove               Stops and completely removes the Node Exporter.
  --help                 Displays this help message.

${BOLD}OPTIONS:${COLOR_RESET}
  --user <name>          Set the service user. Defaults to 'node_exporter'.
  --group <name>         Set the service group. Defaults to 'node_exporter'.
  --port <number>        Set the data port. Defaults to '9100'.

${BOLD}EXAMPLES:${COLOR_RESET}
  sudo $0 --install
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

    # Set the service file path now that user might have been customized
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
