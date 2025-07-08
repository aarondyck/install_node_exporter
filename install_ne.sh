#!/usr/bin/env bash

# ==============================================================================
# Node Exporter Installer & Uninstaller
#
# This script installs or removes the Prometheus Node Exporter on systems
# using systemd and apt, dnf, or yum package managers.
#
# Usage:
#   sudo ./script.sh --install
#   sudo ./script.sh --remove
#   ./script.sh --help
# ==============================================================================

# --- Strict Mode & Error Handling ---
# -e: exit immediately if a command exits with a non-zero status.
# -u: treat unset variables as an error.
# -o pipefail: the return value of a pipeline is the status of the last command
#              to exit with a non-zero status, or zero if no command exited
#              with a non-zero status.
set -euo pipefail

# --- Configuration Variables (readonly) ---
readonly SERVICE_USER="node_exporter"
readonly SERVICE_GROUP="node_exporter"
readonly BINARY_PATH="/usr/local/bin/node_exporter"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_USER}.service"
readonly DATA_PORT="9100"
readonly ARCH="amd64" # Change if you are on a different architecture

# --- Color & Formatting Variables ---
# \e[...m is the escape sequence for colors.
# tput is used to ensure compatibility.
readonly COLOR_GREEN=$(tput setaf 2)
readonly COLOR_YELLOW=$(tput setaf 3)
readonly COLOR_RED=$(tput setaf 1)
readonly COLOR_RESET=$(tput sgr0)
readonly BOLD=$(tput bold)

# --- Logging Functions ---
# msg() is a general-purpose logging function.
msg() {
    echo >&2 -e "${1-}"
}

# success(), notice(), and fatal() are helpers for different log levels.
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
# Create a temporary directory that will be cleaned up automatically on exit.
# The 'trap' command sets up a cleanup action for the EXIT signal.
TMPDIR=$(mktemp -d)
trap 'msg "\n--- Cleaning up temporary files ---"; rm -rf "$TMPDIR"' EXIT

#==============================================================================
# --- HELPER FUNCTIONS ---
#==============================================================================

# --- Check if the script is run as root ---
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fatal "This script must be run as root or with sudo."
    fi
}

# --- Check for required command-line tools ---
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
        fatal "Missing required packages: ${missing_packages[*]}. Please install them and rerun the script."
    fi
    msg "✅ All required packages are installed."
}

# --- Create system user and group ---
setup_user_and_group() {
    msg "--- Creating user and group '${SERVICE_USER}' ---"
    if ! getent group "$SERVICE_GROUP" >/dev/null; then
        groupadd --system "$SERVICE_GROUP"
    fi
    if ! getent passwd "$SERVICE_USER" >/dev/null; then
        useradd --system \
            -d /var/lib/node_exporter -s /bin/false \
            -g "$SERVICE_GROUP" "$SERVICE_USER"
    fi
}

# --- Download and install the binary ---
download_and_install_binary() {
    msg "--- Downloading and installing Node Exporter ---"
    cd "$TMPDIR"

    local latest_url
    latest_url=$(curl -s "https://api.github.com/repos/prometheus/node_exporter/releases/latest" | jq -r ".assets[] | select(.name | contains(\"linux-${ARCH}.tar.gz\")) | .browser_download_url")

    if [[ -z "$latest_url" ]]; then
        fatal "Could not automatically find the download URL for arch '${ARCH}'."
    fi

    msg "--- Latest version found: ${latest_url} ---"
    wget -q --show-progress "$latest_url"

    local tar_file
    tar_file=$(basename "$latest_url")
    tar -xf "$tar_file"

    local extracted_dir
    extracted_dir=${tar_file%.tar.gz}

    # The 'install' command is preferred over 'mv' as it can set ownership and permissions in one step.
    install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0755 "${extracted_dir}/node_exporter" "${BINARY_PATH}"
}

# --- Create the systemd service file ---
create_systemd_service() {
    msg "--- Creating systemd service file ---"
    # Using a HEREDOC to write the service file configuration.
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
Type=simple
ExecStart=${BINARY_PATH}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

# --- Configure the firewall ---
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
        notice "Please manually open port ${DATA_PORT} if a firewall is installed."
    fi
}

#==============================================================================
# --- MAIN LOGIC FUNCTIONS ---
#==============================================================================

install_node_exporter() {
    msg "\n${BOLD}Starting Node Exporter Installation...${COLOR_RESET}"

    # Stop and remove any previous installation to ensure a clean state.
    if command -v "$BINARY_PATH" &>/dev/null; then
        notice "Previous installation detected. Removing it first."
        remove_node_exporter
        msg "\n--- Continuing with new installation ---"
    fi

    check_dependencies
    setup_user_and_group
    download_and_install_binary
    create_systemd_service

    systemctl daemon-reload
    setup_firewall

    msg "--- Enabling and starting Node Exporter service ---"
    # --now enables and starts the service in one command.
    systemctl enable --now "${SERVICE_USER}"

    success "Node Exporter has been installed and started!"
    msg "--- To check status: ${BOLD}sudo systemctl status ${SERVICE_USER}${COLOR_RESET} ---"
    msg "--- Metrics endpoint: ${BOLD}http://<your_server_ip>:${DATA_PORT}/metrics${COLOR_RESET} ---"
}

remove_node_exporter() {
    msg "\n${BOLD}Starting Node Exporter Removal...${COLOR_RESET}"

    if [[ -f "$SERVICE_FILE" ]]; then
        msg "--- Stopping and disabling service ---"
        systemctl stop "${SERVICE_USER}" || true
        systemctl disable "${SERVICE_USER}" || true
    fi

    # --- Remove firewall rules ---
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
    groupdel "$SERVICE_GROUP" >/dev/null 2>&1 || true

    success "Node Exporter has been completely removed."
}

# --- Print usage instructions ---
show_help() {
    cat <<EOF
${BOLD}Node Exporter Management Script${COLOR_RESET}

This script installs or removes the Prometheus Node Exporter.
It must be run with root privileges for installation and removal.

${BOLD}USAGE:${COLOR_RESET}
  sudo $0 [command]

${BOLD}COMMANDS:${COLOR_RESET}
  --install     Installs and starts the Node Exporter service.
  --remove      Stops and completely removes the Node Exporter.
  --help        Displays this help message.

EOF
}

#==============================================================================
# --- SCRIPT ENTRYPOINT ---
#==============================================================================
main() {
    # If no arguments are provided, show help.
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi

    # Parse command-line arguments.
    case "$1" in
        --install)
            check_root
            install_node_exporter
            ;;
        --remove)
            check_root
            remove_node_exporter
            ;;
        --help)
            show_help
            ;;
        *)
            fatal "Invalid argument: $1. Use --help to see available options."
            ;;
    esac
}

# Pass all script arguments to the main function.
main "$@"
