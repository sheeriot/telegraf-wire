#!/usr/bin/env bash
#
# Telegraf Setup Script
# Generates optimized Telegraf configuration with versioned measurement names
#
# Requires Bash 5.2 or greater
# Can be run via: curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/trunk/scripts/setup-telegraf.sh | bash

set -euo pipefail

# Script metadata
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="${BASH_SOURCE[0]%/*}"

# Protect IFS - ensure default value
IFS=$' \t\n'

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
declare MODE=""
declare MODE_SET_VIA_ARGS=false
declare -A CONFIG=(
    [hostname]=""
    [influx_url]=""
    [influx_org]=""
    [influx_bucket]=""
    [influx_token]=""
)

# Error handler using ERR trap (Bash 5.2+ feature)
error_handler() {
    local exit_code=$?
    local line_number=${1:-${BASH_LINENO[0]}}
    local command="${2:-${BASH_COMMAND}}"
    
    if [[ $exit_code -ne 0 ]]; then
        error "Error occurred at line $line_number: $command" >&2
        error "Exit code: $exit_code" >&2
    fi
    
    return $exit_code
}

# Set ERR trap for better error handling
trap 'error_handler ${LINENO} "${BASH_COMMAND}"' ERR

# Function to print colored messages
info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check Bash version (requires 5.2+)
check_bash_version() {
    local bash_version
    local major minor patch
    
    bash_version="${BASH_VERSION%%.*}"
    if [[ ${BASH_VERSINFO[0]} -lt 5 ]] || \
       ([[ ${BASH_VERSINFO[0]} -eq 5 ]] && [[ ${BASH_VERSINFO[1]} -lt 2 ]]); then
        error "This script requires Bash 5.2 or greater."
        error "Current version: ${BASH_VERSION}"
        error "Please upgrade Bash or use a compatible version."
        exit 1
    fi
}

# Detect if script is running from pipe (web execution)
detect_web_execution() {
    # If stdin is a TTY and script file exists, not from pipe
    if [[ -t 0 ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
        return 1  # Not from pipe
    else
        return 0  # Likely from pipe
    fi
}

# Show warning if running from web
warn_web_execution() {
    if detect_web_execution; then
        warn "This script appears to be running from a pipe (web execution)."
        warn "Please review the script source before executing:"
        warn "  ${BASH_SOURCE[0]:-unknown}"
        echo ""
        
        # Check if we have an interactive terminal for confirmation
        if [[ ! -t 0 ]]; then
            error "This script requires an interactive terminal for safe execution."
            error "Please download and review the script before running it locally."
            exit 1
        fi
        
        read -r -p "Continue anyway? (yes/no): " confirm || {
            error "Failed to read input. Please run from an interactive terminal."
            exit 1
        }
        if [[ ! "${confirm,,}" =~ ^(yes|y)$ ]]; then
            info "Execution cancelled by user."
            exit 0
        fi
        echo ""
    fi
}

# Validate URL format using regex (Bash 5.2+ BASH_REMATCH)
validate_url() {
    local url="$1"
    local url_pattern='^https?://[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*(/.*)?$'
    
    if [[ ! "$url" =~ $url_pattern ]]; then
        return 1
    fi
    return 0
}

# Validate hostname format
validate_hostname() {
    local hostname="$1"
    local hostname_pattern='^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$'
    
    if [[ -z "$hostname" ]]; then
        return 0  # Empty is OK (optional field)
    fi
    
    if [[ ! "$hostname" =~ $hostname_pattern ]]; then
        return 1
    fi
    return 0
}

# Validate organization/bucket name (alphanumeric, hyphens, underscores)
validate_identifier() {
    local identifier="$1"
    local identifier_pattern='^[a-zA-Z0-9_-]+$'
    
    if [[ ! "$identifier" =~ $identifier_pattern ]]; then
        return 1
    fi
    return 0
}

# Sanitize input to prevent code injection
sanitize_input() {
    local input="$1"
    # Remove any characters that could be used for injection
    # Allow: alphanumeric, spaces, dots, hyphens, underscores, colons, slashes, @
    echo "${input//[^a-zA-Z0-9 ._\-:@\/]/}"
}

# Prompt for input with validation using nameref (Bash 5.2+ feature)
prompt_input() {
    local -n result_var=$1  # Nameref for cleaner variable passing
    local prompt="$2"
    local default_value="${3:-}"
    local required="${4:-true}"
    local validator="${5:-}"  # Optional validation function name
    local value=""
    local sanitized_value=""
    
    while true; do
        if [[ -n "$default_value" ]]; then
            read -r -p "$prompt [$default_value]: " value
            value="${value:-$default_value}"
        else
            read -r -p "$prompt: " value
        fi
        
        # Sanitize input
        sanitized_value=$(sanitize_input "$value")
        
        if [[ -z "$sanitized_value" && "$required" == "true" ]]; then
            error "This field is required. Please enter a value."
            continue
        fi
        
        # Run validator if provided
        if [[ -n "$validator" ]] && [[ -n "$sanitized_value" ]]; then
            if ! "$validator" "$sanitized_value"; then
                error "Invalid format. Please try again."
                continue
            fi
        fi
        
        result_var="$sanitized_value"
        break
    done
}

# Prompt for secret input (hidden) using nameref
prompt_secret() {
    local -n result_var=$1  # Nameref
    local prompt="$2"
    local value=""
    local sanitized_value=""
    
    while true; do
        read -rs -p "$prompt: " value
        echo ""
        
        # Sanitize input (but preserve token characters)
        sanitized_value=$(sanitize_input "$value")
        
        if [[ -z "$sanitized_value" ]]; then
            error "This field is required. Please enter a value."
            continue
        fi
        
        # Basic token validation (should be reasonable length)
        if [[ ${#sanitized_value} -lt 10 ]]; then
            error "Token seems too short. Please verify and try again."
            continue
        fi
        
        result_var="$sanitized_value"
        break
    done
}

# Show comprehensive help
show_help() {
    cat <<EOF
${BLUE}Telegraf Setup Script${NC} - Version ${SCRIPT_VERSION}

${GREEN}Usage:${NC} ${SCRIPT_NAME} [OPTIONS] [MODE]

${GREEN}Modes:${NC}
  pack (default)     Generate configuration files in timestamped folder
  live               Install configuration directly to /etc/telegraf/ (requires sudo)

${GREEN}Options:${NC}
  -h, --help         Show this help message
  -v, --version      Show version information

${GREEN}Examples:${NC}
  # Generate config files (pack mode - default, will prompt for mode)
  ./${SCRIPT_NAME}
  ./${SCRIPT_NAME} pack
  
  # Install locally (requires sudo, will prompt for mode)
  ./${SCRIPT_NAME} live
  
  # Run from web
  curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/trunk/scripts/${SCRIPT_NAME} | bash

${GREEN}Description:${NC}
  This script generates optimized Telegraf configuration files with versioned
  measurement names (v2_ prefix) and optimized collection intervals.
  
  When run interactively, you'll be prompted to choose between pack mode (generate
  files in a timestamped output folder) or live mode (install directly to /etc/telegraf/).
  
${GREEN}Security:${NC}
  - All inputs are validated and sanitized
  - Environment files contain sensitive tokens - keep them secure!
  - Script detects web execution and warns before proceeding

${GREEN}Requirements:${NC}
  - Bash 5.2 or greater
  - sudo access (for live/--local mode)
  - Telegraf installed (for live/--local mode)

EOF
}

# Show version
show_version() {
    echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
    echo "Bash version: ${BASH_VERSION}"
}

# Parse command line arguments
parse_arguments() {
    local args=("$@")
    local i=0
    
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            pack|live)
                MODE="${args[$i]}"
                MODE_SET_VIA_ARGS=true
                ;;
            *)
                error "Unknown option: ${args[$i]}"
                echo ""
                show_help
                exit 1
                ;;
        esac
        ((i++))
    done
}

# Generate short timestamp (YYMMDD_HHMMSS)
generate_timestamp() {
    date +"%y%m%d_%H%M%S"
}

# Backup existing file
backup_file() {
    local file_path="$1"
    
    if [[ -f "$file_path" ]]; then
        local backup_path="${file_path}.bak.$(generate_timestamp)"
        info "Backing up existing file: $file_path -> $backup_path"
        sudo cp "$file_path" "$backup_path" || {
            error "Failed to backup file: $file_path"
            return 1
        }
    fi
}

# Generate telegraf.conf
generate_config() {
    cat <<'EOF'
[agent]
  interval = "120s"
  round_interval = true
  flush_interval = "120s"
  flush_jitter = "0s"

  metric_batch_size = 1000
  metric_buffer_limit = 3000

  precision = "1s"

  hostname = "${HOSTNAME}"
  omit_hostname = false

  skip_processors_after_aggregators = true

# CPU metrics - collected every 2 minutes
[[inputs.cpu]]
  interval = "120s"
  percpu = false
  totalcpu = true
  collect_cpu_time = false
  report_active = true

# Memory metrics - collected every 5 minutes
[[inputs.mem]]
  interval = "300s"
  fieldinclude = ["available", "available_percent"]

# Disk metrics - collected hourly
[[inputs.disk]]
  interval = "3600s"
  ignore_fs = ["tmpfs", "devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs"]

# System metrics - collected every 5 minutes
[[inputs.system]]
  interval = "300s"

# Rename processors for versioned measurement names
[[processors.rename]]
  [[processors.rename.replace]]
    measurement = "cpu"
    dest = "v2_cpu"

[[processors.rename]]
  [[processors.rename.replace]]
    measurement = "mem"
    dest = "v2_mem"

[[processors.rename]]
  [[processors.rename.replace]]
    measurement = "disk"
    dest = "v2_disk"

[[processors.rename]]
  [[processors.rename.replace]]
    measurement = "system"
    dest = "v2_system"

# InfluxDB v2 output
[[outputs.influxdb_v2]]
  urls = ["${INFLUX_URL}"]
  token = "${INFLUX_TOKEN}"
  organization = "${INFLUX_ORG}"
  bucket = "${INFLUX_BUCKET}"
  timeout = "10s"
  content_encoding = "gzip"
EOF
}

# Generate telegraf.env using safe variable expansion
generate_env() {
    local hostname="${1:-}"
    local influx_url="${2:-}"
    local influx_org="${3:-}"
    local influx_bucket="${4:-}"
    local influx_token="${5:-}"
    
    # Generate env file compatible with systemd EnvironmentFile
    # systemd supports both quoted and unquoted values, but quoting is necessary
    # for values containing spaces or special characters to prevent truncation
    # Use ${var@Q} for safe shell quoting (Bash 5.2+ feature)
    cat <<EOF
HOSTNAME=${hostname@Q}

INFLUX_ORG=${influx_org@Q}
INFLUX_BUCKET=${influx_bucket@Q}
INFLUX_TOKEN=${influx_token@Q}

INFLUX_URL=${influx_url@Q}
EOF
}

# Check if running on Debian/Ubuntu
is_debian_system() {
    # /etc/debian_version is the definitive marker for Debian systems
    # Check it first, then fall back to os-release if needed
    if [[ -f /etc/debian_version ]]; then
        return 0
    fi
    
    # Check os-release as fallback for Ubuntu/Debian derivatives
    if [[ -f /etc/os-release ]]; then
        if grep -qiE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
            return 0
        fi
    fi
    
    return 1
}

# Show Telegraf installation instructions for pack mode
show_telegraf_install_instructions() {
    local output_dir="$1"
    
    echo ""
    info "To install Telegraf and use these configuration files:"
    echo ""
    echo "1. Install Telegraf:"
    echo "   # Ubuntu/Debian (recommended - checks status first):"
    echo "   ./scripts/install-telegraf.sh"
    echo ""
    echo "   # Or manually:"
    echo "   curl --silent --location -O https://repos.influxdata.com/influxdata-archive.key"
    echo "   gpg --show-keys --with-fingerprint --with-colons ./influxdata-archive.key 2>&1 \\"
    echo "   | grep -q '^fpr:\+24C975CBA61A024EE1B631787C3D57159FC2F927:\$' \\"
    echo "   && cat influxdata-archive.key \\"
    echo "   | gpg --dearmor \\"
    echo "   | sudo tee /etc/apt/keyrings/influxdata-archive.gpg > /dev/null \\"
    echo "   && echo 'deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main' \\"
    echo "   | sudo tee /etc/apt/sources.list.d/influxdata.list"
    echo "   sudo apt-get update && sudo apt-get install telegraf"
    echo ""
    echo "   # RHEL/CentOS/Rocky Linux:"
    echo "   sudo yum install -y telegraf"
    echo ""
    echo "   # Or using dnf (newer RHEL-based systems):"
    echo "   sudo dnf install -y telegraf"
    echo ""
    echo "2. Copy configuration files:"
    echo "   sudo cp ${output_dir}/telegraf.conf /etc/telegraf/"
    echo "   sudo cp ${output_dir}/telegraf.env /etc/telegraf/"
    echo ""
    echo "3. Set proper permissions:"
    echo "   sudo chmod 644 /etc/telegraf/telegraf.conf"
    echo "   sudo chmod 600 /etc/telegraf/telegraf.env"
    echo ""
    echo "4. Start and enable Telegraf:"
    echo "   sudo systemctl enable telegraf"
    echo "   sudo systemctl start telegraf"
    echo "   sudo systemctl status telegraf"
    echo ""
    echo "5. Verify it's working:"
    echo "   sudo telegraf --config /etc/telegraf/telegraf.conf --test"
    echo ""
}

# Check sudo access
check_sudo_access() {
    if ! sudo -n true 2>/dev/null; then
        warn "This requires sudo access. You may be prompted for your password."
        if ! sudo -v; then
            error "Failed to obtain sudo access. Exiting."
            return 1
        fi
    fi
    return 0
}

# Handle Telegraf installation prompt
handle_telegraf_installation() {
    local output_dir="$1"
    
    echo ""
    read -r -p "Install and configure Telegraf automatically? (requires sudo) (yes/no): " install_choice
    if [[ ! "${install_choice,,}" =~ ^(yes|y)$ ]]; then
        echo ""
        read -r -p "Show manual installation instructions? (yes/no): " show_manual
        if [[ "${show_manual,,}" =~ ^(yes|y)$ ]]; then
            show_telegraf_install_instructions "$output_dir"
        fi
        return
    fi
    
    if ! is_debian_system; then
        warn "Automatic installation is only available for Debian/Ubuntu systems."
        echo ""
        read -r -p "Show manual installation instructions? (yes/no): " show_manual
        if [[ "${show_manual,,}" =~ ^(yes|y)$ ]]; then
            show_telegraf_install_instructions "$output_dir"
        fi
        return
    fi
    
    if ! check_sudo_access; then
        return
    fi
    
    echo ""
    info "Installing and configuring Telegraf..."
    
    # Step 1: Install Telegraf software
    info "Step 1: Installing Telegraf..."
    local install_script=""
    if [[ -f "${SCRIPT_DIR}/install-telegraf.sh" ]]; then
        install_script="${SCRIPT_DIR}/install-telegraf.sh"
    elif [[ -f "./scripts/install-telegraf.sh" ]]; then
        install_script="./scripts/install-telegraf.sh"
    elif [[ -f "install-telegraf.sh" ]]; then
        install_script="./install-telegraf.sh"
    fi
    
    if [[ -z "$install_script" ]] || [[ ! -f "$install_script" ]]; then
        error "Installation script not found."
        show_telegraf_install_instructions "$output_dir"
        return
    fi
    
    bash "$install_script" || {
        error "Installation failed."
        read -r -p "Show manual instructions? (yes/no): " show_manual
        [[ "${show_manual,,}" =~ ^(yes|y)$ ]] && show_telegraf_install_instructions "$output_dir"
        return
    }
    
    # Step 2: Install config files
    info "Step 2: Installing configuration..."
    [[ ! -d "/etc/telegraf" ]] && sudo mkdir -p /etc/telegraf
    
    if [[ -f "/etc/telegraf/telegraf.conf" ]]; then
        sudo cp /etc/telegraf/telegraf.conf "/etc/telegraf/telegraf.conf.bak.$(generate_timestamp)" 2>/dev/null || true
    fi
    if [[ -f "/etc/telegraf/telegraf.env" ]]; then
        sudo cp /etc/telegraf/telegraf.env "/etc/telegraf/telegraf.env.bak.$(generate_timestamp)" 2>/dev/null || true
    fi
    
    sudo cp "${output_dir}/telegraf.conf" /etc/telegraf/ && \
    sudo cp "${output_dir}/telegraf.env" /etc/telegraf/ && \
    sudo chmod 644 /etc/telegraf/telegraf.conf && \
    sudo chmod 600 /etc/telegraf/telegraf.env || {
        error "Failed to install configuration files."
        return
    }
    
    # Create symlink from /etc/default/telegraf to /etc/telegraf/telegraf.env
    # This allows systemd to load the env file while keeping the better-named file
    if [[ -f "/etc/default/telegraf" ]] && [[ ! -L "/etc/default/telegraf" ]]; then
        # Backup existing file if it's not already a symlink
        sudo cp /etc/default/telegraf "/etc/default/telegraf.bak.$(generate_timestamp)" 2>/dev/null || true
        sudo rm -f /etc/default/telegraf
    fi
    
    # Create or update symlink
    sudo ln -sf /etc/telegraf/telegraf.env /etc/default/telegraf || {
        error "Failed to create symlink"
        return
    }
    
    # Step 3: Enable and start service
    info "Step 3: Starting service..."
    sudo systemctl enable telegraf && sudo systemctl restart telegraf || {
        error "Failed to start service."
        return
    }
    
    # Step 4: Validate
    info "Step 4: Validating..."
    local status_ok=true
    sudo systemctl is-active --quiet telegraf && info "✓ Service running" || { warn "✗ Service not running"; status_ok=false; }
    sudo systemctl is-enabled --quiet telegraf && info "✓ Auto-start enabled" || { warn "✗ Auto-start disabled"; status_ok=false; }
    sudo telegraf --config /etc/telegraf/telegraf.conf --test > /dev/null 2>&1 && info "✓ Config test passed" || { warn "✗ Config test failed"; status_ok=false; }
    
    echo ""
    if [[ "$status_ok" == "true" ]]; then
        info "Complete!"
    else
        warn "Complete with warnings."
    fi
    
    echo ""
    info "Useful commands to inspect and test:"
    echo ""
    echo "  Check service status:"
    echo "    sudo systemctl status telegraf"
    echo ""
    echo "  View recent logs:"
    echo "    sudo journalctl -u telegraf -n 50 --no-pager"
    echo ""
    echo "  Follow logs in real-time:"
    echo "    sudo journalctl -u telegraf -f"
    echo ""
    echo "  Test configuration:"
    echo "    sudo telegraf --config /etc/telegraf/telegraf.conf --test"
    echo ""
}

# Pack mode: Generate files in timestamped output folder
pack_mode() {
    local timestamp
    local output_dir
    
    timestamp=$(generate_timestamp)
    output_dir="output_${timestamp}"
    
    info "Running in PACK mode - generating files in: ${output_dir}"
    
    # Validate and create output directory (prevent directory traversal)
    if [[ "$output_dir" =~ \.\. ]] || [[ "$output_dir" =~ ^/ ]]; then
        error "Invalid output directory name. Security check failed."
        exit 1
    fi
    
    mkdir -p "$output_dir" || {
        error "Failed to create output directory: $output_dir"
        exit 1
    }
    
    # Collect environment variables
    echo ""
    info "Please provide the following configuration:"
    echo ""
    
    local system_hostname
    system_hostname=$(hostname 2>/dev/null || echo "localhost")
    
    prompt_input CONFIG[hostname] "Hostname" "$system_hostname" "false" "validate_hostname"
    prompt_input CONFIG[influx_url] "InfluxDB URL" "https://us-east-1-1.aws.cloud2.influxdata.com" "true" "validate_url"
    prompt_input CONFIG[influx_org] "InfluxDB Organization" "" "true" "validate_identifier"
    prompt_input CONFIG[influx_bucket] "InfluxDB Bucket" "" "true" "validate_identifier"
    prompt_secret CONFIG[influx_token] "InfluxDB Token"
    
    # Generate files using safe file operations
    info "Generating telegraf.conf..."
    if ! generate_config > "${output_dir}/telegraf.conf"; then
        error "Failed to generate telegraf.conf"
        exit 1
    fi
    
    info "Generating telegraf.env..."
    if ! generate_env \
        "${CONFIG[hostname]}" \
        "${CONFIG[influx_url]}" \
        "${CONFIG[influx_org]}" \
        "${CONFIG[influx_bucket]}" \
        "${CONFIG[influx_token]}" > "${output_dir}/telegraf.env"; then
        error "Failed to generate telegraf.env"
        exit 1
    fi
    
    # Set proper permissions
    chmod 644 "${output_dir}/telegraf.conf"
    chmod 600 "${output_dir}/telegraf.env"
    
    echo ""
    info "Files generated successfully in: ${output_dir}/"
    info "  - telegraf.conf"
    info "  - telegraf.env"
    echo ""
    warn "Remember to keep telegraf.env secure - it contains your InfluxDB token!"
    
    # Handle Telegraf installation
    handle_telegraf_installation "$output_dir"
}

# Check sudo access for live mode
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        if [[ ! -t 0 ]]; then
            error "Live mode requires sudo access and an interactive terminal."
            exit 1
        fi
        warn "Live mode requires sudo access. You may be prompted for your password."
        if ! sudo -v; then
            error "Failed to obtain sudo access. Exiting."
            exit 1
        fi
    fi
    info "Sudo access confirmed for live mode."
}

# Mask token for display (first 4 and last 4 visible)
mask_token() {
    local token="$1"
    local len=${#token}
    
    if [[ $len -le 8 ]]; then
        # If token is 8 chars or less, just show asterisks
        echo "****"
    else
        # Show first 4, ..., last 4
        echo "${token:0:4}...${token: -4}"
    fi
}

# Read existing config from telegraf.env
read_existing_config() {
    local env_file="/etc/telegraf/telegraf.env"
    
    if [[ ! -f "$env_file" ]]; then
        return 1
    fi
    
    # Read and parse env file
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # Parse KEY=VALUE format
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]// /}"
            local value="${BASH_REMATCH[2]}"
            
            # Remove quotes (handles both single and double quotes, including shell-quoted format)
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"
            value="${value#$'\\''}"
            value="${value%$'\\''}"
            
            case "$key" in
                HOSTNAME)
                    CONFIG[hostname]="$value"
                    ;;
                INFLUX_URL)
                    CONFIG[influx_url]="$value"
                    ;;
                INFLUX_ORG)
                    CONFIG[influx_org]="$value"
                    ;;
                INFLUX_BUCKET)
                    CONFIG[influx_bucket]="$value"
                    ;;
                INFLUX_TOKEN)
                    CONFIG[influx_token]="$value"
                    ;;
            esac
        fi
    done < <(sudo cat "$env_file" 2>/dev/null)
    
    # Verify we got at least the required fields
    if [[ -z "${CONFIG[influx_url]}" ]] || [[ -z "${CONFIG[influx_org]}" ]] || \
       [[ -z "${CONFIG[influx_bucket]}" ]] || [[ -z "${CONFIG[influx_token]}" ]]; then
        return 1
    fi
    
    return 0
}

# Live mode: Install files to /etc/telegraf/
live_mode() {
    info "Running in LIVE mode - installing to /etc/telegraf/"
    
    # Check if we have a TTY for interactive input
    if [[ ! -t 0 ]]; then
        error "Live mode requires an interactive terminal. Please run from a terminal."
        exit 1
    fi
    
    check_sudo
    
    # Ensure /etc/telegraf directory exists
    if [[ ! -d "/etc/telegraf" ]]; then
        warn "/etc/telegraf directory does not exist. Creating it..."
        sudo mkdir -p /etc/telegraf || {
            error "Failed to create /etc/telegraf directory"
            exit 1
        }
    fi
    
    # Read existing config if it exists
    local has_existing=false
    if [[ -f "/etc/telegraf/telegraf.env" ]]; then
        if read_existing_config; then
            has_existing=true
            echo ""
            info "Found existing configuration:"
            echo ""
            echo "  Hostname: ${CONFIG[hostname]:-(not set)}"
            echo "  InfluxDB URL: ${CONFIG[influx_url]:-(not set)}"
            echo "  Organization: ${CONFIG[influx_org]:-(not set)}"
            echo "  Bucket: ${CONFIG[influx_bucket]:-(not set)}"
            if [[ -n "${CONFIG[influx_token]:-}" ]]; then
                echo "  Token: $(mask_token "${CONFIG[influx_token]}")"
            else
                echo "  Token: (not set)"
            fi
        else
            warn "Existing config file found but could not be read. Will prompt for new values."
        fi
    fi
    
    # Ask if they want to use existing or change
    local use_existing=false
    if [[ "$has_existing" == "true" ]]; then
        echo ""
        read -r -p "Use existing configuration? (yes/no): " use_existing_choice || {
            error "Failed to read input. Please ensure you're running from an interactive terminal."
            exit 1
        }
        if [[ "${use_existing_choice,,}" =~ ^(yes|y)$ ]]; then
            use_existing=true
            info "Using existing configuration."
        fi
    fi
    
    # Collect environment variables (skip if using existing, otherwise use existing as defaults)
    if [[ "$use_existing" != "true" ]]; then
        echo ""
        info "Please provide the following configuration:"
        echo ""
        
        # Set defaults from existing config or system defaults
        local default_hostname="${CONFIG[hostname]:-}"
        if [[ -z "$default_hostname" ]]; then
            default_hostname=$(hostname 2>/dev/null || echo "localhost")
        fi
        
        local default_url="${CONFIG[influx_url]:-https://us-east-1-1.aws.cloud2.influxdata.com}"
        local default_org="${CONFIG[influx_org]:-}"
        local default_bucket="${CONFIG[influx_bucket]:-}"
        
        prompt_input CONFIG[hostname] "Hostname" "$default_hostname" "false" "validate_hostname"
        prompt_input CONFIG[influx_url] "InfluxDB URL" "$default_url" "true" "validate_url"
        prompt_input CONFIG[influx_org] "InfluxDB Organization" "$default_org" "true" "validate_identifier"
        prompt_input CONFIG[influx_bucket] "InfluxDB Bucket" "$default_bucket" "true" "validate_identifier"
        
        # For token, if we have existing, ask if they want to keep it
        if [[ -n "${CONFIG[influx_token]:-}" ]]; then
            echo ""
            read -r -p "Keep existing InfluxDB Token? (yes/no): " keep_token
            if [[ ! "${keep_token,,}" =~ ^(yes|y)$ ]]; then
                prompt_secret CONFIG[influx_token] "InfluxDB Token"
            fi
        else
            prompt_secret CONFIG[influx_token] "InfluxDB Token"
        fi
    fi
    
    # Backup existing files
    backup_file "/etc/telegraf/telegraf.conf"
    backup_file "/etc/telegraf/telegraf.env"
    
    # Generate and install files
    info "Generating telegraf.conf..."
    if ! generate_config | sudo tee /etc/telegraf/telegraf.conf > /dev/null; then
        error "Failed to install telegraf.conf"
        exit 1
    fi
    
    info "Generating telegraf.env..."
    if ! generate_env \
        "${CONFIG[hostname]}" \
        "${CONFIG[influx_url]}" \
        "${CONFIG[influx_org]}" \
        "${CONFIG[influx_bucket]}" \
        "${CONFIG[influx_token]}" | sudo tee /etc/telegraf/telegraf.env > /dev/null; then
        error "Failed to install telegraf.env"
        exit 1
    fi
    
    # Set proper permissions
    sudo chmod 644 /etc/telegraf/telegraf.conf
    sudo chmod 600 /etc/telegraf/telegraf.env
    
    # Create symlink from /etc/default/telegraf to /etc/telegraf/telegraf.env
    # This allows systemd to load the env file while keeping the better-named file
    if [[ -f "/etc/default/telegraf" ]] && [[ ! -L "/etc/default/telegraf" ]]; then
        # Backup existing file if it's not already a symlink
        sudo cp /etc/default/telegraf "/etc/default/telegraf.bak.$(generate_timestamp)" 2>/dev/null || true
        sudo rm -f /etc/default/telegraf
    fi
    
    # Create or update symlink
    sudo ln -sf /etc/telegraf/telegraf.env /etc/default/telegraf || {
        error "Failed to create symlink"
        exit 1
    }
    
    echo ""
    info "Configuration installed successfully."
    
    # Restart service
    if systemctl is-active --quiet telegraf 2>/dev/null || systemctl is-enabled --quiet telegraf 2>/dev/null; then
        info "Restarting Telegraf service..."
        sudo systemctl restart telegraf && info "Service restarted." || warn "Failed to restart service."
    fi
    
    # Show helpful commands
    echo ""
    info "Useful commands to inspect and test:"
    echo ""
    echo "  Check service status:"
    echo "    sudo systemctl status telegraf"
    echo ""
    echo "  View recent logs:"
    echo "    sudo journalctl -u telegraf -n 50 --no-pager"
    echo ""
    echo "  Follow logs in real-time:"
    echo "    sudo journalctl -u telegraf -f"
    echo ""
    echo "  Test configuration:"
    echo "    sudo telegraf --config /etc/telegraf/telegraf.conf --test"
    echo ""
}

# Main function
main() {
    # Check Bash version first
    check_bash_version
    
    # Parse arguments
    parse_arguments "$@"
    
    # Warn if running from web
    warn_web_execution
    
    echo "=========================================="
    echo "  Telegraf Setup Script"
    echo "  Version: ${SCRIPT_VERSION}"
    echo "=========================================="
    echo ""
    
    # Ask for mode if not specified via command line
    if [[ "$MODE_SET_VIA_ARGS" != "true" ]]; then
        if [[ -t 0 ]]; then
            echo "Select mode:"
            echo "  1) Pack - Generate config files in output folder (default)"
            echo "  2) Live - Install directly to /etc/telegraf/ (requires sudo)"
            echo ""
            read -r -p "Enter choice [1]: " mode_choice
            mode_choice="${mode_choice:-1}"
            
            case "$mode_choice" in
                1|pack)
                    MODE="pack"
                    ;;
                2|live)
                    MODE="live"
                    ;;
                *)
                    warn "Invalid choice, using pack mode."
                    MODE="pack"
                    ;;
            esac
        else
            # Non-interactive, default to pack
            MODE="pack"
        fi
    fi
    
    echo ""
    info "Mode: ${MODE}"
    echo ""
    
    case "$MODE" in
        pack)
            pack_mode
            ;;
        live)
            live_mode
            ;;
        *)
            error "Invalid mode: ${MODE}"
            echo ""
            show_help
            exit 1
            ;;
    esac
    
    echo ""
    info "Setup complete!"
}

# Run main function with all arguments
main "$@"
