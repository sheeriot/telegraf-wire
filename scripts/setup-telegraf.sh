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
declare MODE="pack"
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
        read -r -p "Continue anyway? (yes/no): " confirm
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
  live, --local      Install configuration directly to /etc/telegraf/ (requires sudo)

${GREEN}Options:${NC}
  -h, --help         Show this help message
  -v, --version      Show version information

${GREEN}Examples:${NC}
  # Generate config files (pack mode - default)
  ./${SCRIPT_NAME}
  ./${SCRIPT_NAME} pack
  
  # Install locally (requires sudo)
  ./${SCRIPT_NAME} --local
  ./${SCRIPT_NAME} live
  
  # Run from web
  curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/trunk/scripts/${SCRIPT_NAME} | bash
  curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/trunk/scripts/${SCRIPT_NAME} | bash -s -- --local

${GREEN}Description:${NC}
  This script generates optimized Telegraf configuration files with versioned
  measurement names (v2_ prefix) and optimized collection intervals.
  
  In pack mode, files are generated in a timestamped output folder.
  In live/--local mode, files are installed directly to /etc/telegraf/.
  
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
            --local)
                MODE="live"
                ;;
            pack|live)
                MODE="${args[$i]}"
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
  interval = "60s"
  round_interval = true
  flush_interval = "60s"
  flush_jitter = "0s"

  metric_batch_size = 1000
  metric_buffer_limit = 3000

  precision = "1s"

  # safest: omit this line (defaults to system hostname)
  # hostname = "${HOSTNAME}"
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
    
    # Use ${var@Q} for safe quoting (Bash 5.2+ feature)
    cat <<EOF
HOSTNAME=${hostname@Q}

INFLUX_ORG=${influx_org@Q}
INFLUX_BUCKET=${influx_bucket@Q}
INFLUX_TOKEN=${influx_token@Q}

INFLUX_URL=${influx_url@Q}
EOF
}

# Show Telegraf installation instructions for pack mode
show_telegraf_install_instructions() {
    local output_dir="$1"
    
    echo ""
    info "To install Telegraf and use these configuration files:"
    echo ""
    echo "1. Install Telegraf:"
    echo "   # Ubuntu/Debian:"
    echo "   sudo apt-get update"
    echo "   sudo apt-get install -y telegraf"
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
    prompt_input CONFIG[influx_url] "InfluxDB URL" "" "true" "validate_url"
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
    
    # Show installation instructions
    show_telegraf_install_instructions "$output_dir"
}

# Check sudo access for live mode
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        warn "Live mode requires sudo access. You may be prompted for your password."
        if ! sudo -v; then
            error "Failed to obtain sudo access. Exiting."
            exit 1
        fi
    fi
    info "Sudo access confirmed for live mode."
}

# Live mode: Install files to /etc/telegraf/
live_mode() {
    info "Running in LIVE mode - installing to /etc/telegraf/"
    
    check_sudo
    
    # Ensure /etc/telegraf directory exists
    if [[ ! -d "/etc/telegraf" ]]; then
        warn "/etc/telegraf directory does not exist. Creating it..."
        sudo mkdir -p /etc/telegraf || {
            error "Failed to create /etc/telegraf directory"
            exit 1
        }
    fi
    
    # Collect environment variables
    echo ""
    info "Please provide the following configuration:"
    echo ""
    
    local system_hostname
    system_hostname=$(hostname 2>/dev/null || echo "localhost")
    
    prompt_input CONFIG[hostname] "Hostname" "$system_hostname" "false" "validate_hostname"
    prompt_input CONFIG[influx_url] "InfluxDB URL" "" "true" "validate_url"
    prompt_input CONFIG[influx_org] "InfluxDB Organization" "" "true" "validate_identifier"
    prompt_input CONFIG[influx_bucket] "InfluxDB Bucket" "" "true" "validate_identifier"
    prompt_secret CONFIG[influx_token] "InfluxDB Token"
    
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
    
    echo ""
    info "Configuration installed successfully to /etc/telegraf/"
    info "  - telegraf.conf (backed up if existed)"
    info "  - telegraf.env (backed up if existed)"
    echo ""
    info "You may need to restart Telegraf service:"
    echo "  sudo systemctl restart telegraf"
    echo "  sudo systemctl status telegraf"
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
    echo "  Mode: ${MODE}"
    echo "=========================================="
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
