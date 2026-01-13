#!/usr/bin/env bash
#
# Telegraf Installation Script
# Installs Telegraf from official InfluxData repository
#

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check if running on Debian/Ubuntu
check_debian() {
    if [[ ! -f /etc/debian_version ]] && [[ ! -f /etc/os-release ]]; then
        error "This script is for Debian/Ubuntu systems only."
        exit 1
    fi
    
    # Check if os-release indicates Debian/Ubuntu
    if [[ -f /etc/os-release ]]; then
        if ! grep -qiE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
            error "This script is for Debian/Ubuntu systems only."
            exit 1
        fi
    fi
}

# Check Telegraf installation status
check_telegraf_status() {
    local policy_output
    local installed_version=""
    local repo_available=false
    
    # Check if apt-cache is available
    if ! command -v apt-cache &> /dev/null; then
        warn "apt-cache not found. Assuming Telegraf needs installation."
        return 1
    fi
    
    policy_output=$(apt-cache policy telegraf 2>/dev/null || echo "")
    
    if [[ -z "$policy_output" ]]; then
        return 1
    fi
    
    # Check if repo is configured (look for repos.influxdata.com)
    if echo "$policy_output" | grep -q "repos.influxdata.com"; then
        repo_available=true
    fi
    
    # Extract installed version
    if command -v telegraf &> /dev/null; then
        installed_version=$(telegraf --version 2>/dev/null | head -n1 || echo "")
    fi
    
    # Check if installed
    if [[ -n "$installed_version" ]]; then
        info "Telegraf is installed: $installed_version"
    else
        warn "Telegraf is not installed."
    fi
    
    # Check repo status
    if [[ "$repo_available" == "true" ]]; then
        info "InfluxData repository is configured."
    else
        warn "InfluxData repository is not configured."
    fi
    
    # Determine if action is needed
    if [[ -z "$installed_version" ]] || [[ "$repo_available" == "false" ]]; then
        return 1
    fi
    
    return 0
}

# Install Telegraf
install_telegraf() {
    info "Installing Telegraf from InfluxData repository..."
    
    # Download and verify GPG key
    curl --silent --location -O https://repos.influxdata.com/influxdata-archive.key || {
        error "Failed to download GPG key"
        exit 1
    }
    
    # Verify fingerprint and add to keyring
    gpg --show-keys --with-fingerprint --with-colons ./influxdata-archive.key 2>&1 \
    | grep -q '^fpr:\+24C975CBA61A024EE1B631787C3D57159FC2F927:$' \
    && cat influxdata-archive.key \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/influxdata-archive.gpg > /dev/null \
    || {
        error "Failed to verify GPG key fingerprint"
        rm -f influxdata-archive.key
        exit 1
    }
    
    # Add repository
    echo 'deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main' \
    | sudo tee /etc/apt/sources.list.d/influxdata.list > /dev/null || {
        error "Failed to add InfluxData repository"
        exit 1
    }
    
    # Clean up key file
    rm -f influxdata-archive.key
    
    # Update and install
    sudo apt-get update && sudo apt-get install -y telegraf || {
        error "Failed to install Telegraf"
        exit 1
    }
    
    info "Telegraf installed successfully."
}

# Main function
main() {
    check_debian
    
    if check_telegraf_status; then
        info "Telegraf is up to date."
        exit 0
    fi
    
    read -r -p "Install/update Telegraf? (yes/no): " confirm
    if [[ ! "${confirm,,}" =~ ^(yes|y)$ ]]; then
        exit 0
    fi
    
    install_telegraf
}

main "$@"
