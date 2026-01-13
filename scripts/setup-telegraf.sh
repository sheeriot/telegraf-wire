#!/bin/bash
#
# Telegraf Setup Script
# Generates optimized Telegraf configuration with versioned measurement names
#
# Usage: ./setup-telegraf.sh [pack|live]
#   pack (default) - Generate files in timestamped output folder
#   live           - Install on current host (requires sudo)
#
# Can be run via: curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/main/scripts/setup-telegraf.sh | bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default mode
MODE="${1:-pack}"

# Validate mode
if [[ "$MODE" != "pack" && "$MODE" != "live" ]]; then
    echo -e "${RED}Error: Invalid mode '$MODE'. Use 'pack' or 'live'.${NC}" >&2
    echo "Usage: $0 [pack|live]"
    exit 1
fi

# Function to print colored messages
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check sudo access for live mode
check_sudo() {
    if [[ "$MODE" == "live" ]]; then
        if ! sudo -n true 2>/dev/null; then
            warn "Live mode requires sudo access. You may be prompted for your password."
            if ! sudo -v; then
                error "Failed to obtain sudo access. Exiting."
                exit 1
            fi
        fi
        info "Sudo access confirmed for live mode."
    fi
}

# Generate short timestamp (YYMMDD_HHMMSS)
generate_timestamp() {
    date +"%y%m%d_%H%M%S"
}

# Prompt for input with validation
prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default_value="${3:-}"
    local required="${4:-true}"
    local value=""
    
    while true; do
        if [[ -n "$default_value" ]]; then
            read -p "$prompt [$default_value]: " value
            value="${value:-$default_value}"
        else
            read -p "$prompt: " value
        fi
        
        if [[ -z "$value" && "$required" == "true" ]]; then
            error "This field is required. Please enter a value."
            continue
        fi
        
        eval "$var_name='$value'"
        break
    done
}

# Prompt for secret input (hidden)
prompt_secret() {
    local prompt="$1"
    local var_name="$2"
    local value=""
    
    while true; do
        read -s -p "$prompt: " value
        echo ""
        
        if [[ -z "$value" ]]; then
            error "This field is required. Please enter a value."
            continue
        fi
        
        eval "$var_name='$value'"
        break
    done
}

# Backup existing file
backup_file() {
    local file_path="$1"
    
    if [[ -f "$file_path" ]]; then
        local backup_path="${file_path}.bak"
        info "Backing up existing file: $file_path -> $backup_path"
        sudo cp "$file_path" "$backup_path"
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

# Generate telegraf.env
generate_env() {
    local hostname="$1"
    local influx_url="$2"
    local influx_org="$3"
    local influx_bucket="$4"
    local influx_token="$5"
    
    cat <<EOF
HOSTNAME=${hostname}

INFLUX_ORG=${influx_org}
INFLUX_BUCKET=${influx_bucket}
INFLUX_TOKEN=${influx_token}

INFLUX_URL=${influx_url}
EOF
}

# Pack mode: Generate files in timestamped output folder
pack_mode() {
    local timestamp=$(generate_timestamp)
    local output_dir="output_${timestamp}"
    
    info "Running in PACK mode - generating files in: $output_dir"
    
    mkdir -p "$output_dir"
    
    # Collect environment variables
    echo ""
    info "Please provide the following configuration:"
    echo ""
    
    local system_hostname=$(hostname)
    prompt_input "Hostname" "HOSTNAME" "$system_hostname" "false"
    
    prompt_input "InfluxDB URL" "INFLUX_URL" "" "true"
    prompt_input "InfluxDB Organization" "INFLUX_ORG" "" "true"
    prompt_input "InfluxDB Bucket" "INFLUX_BUCKET" "" "true"
    prompt_secret "InfluxDB Token" "INFLUX_TOKEN"
    
    # Generate files
    info "Generating telegraf.conf..."
    generate_config > "$output_dir/telegraf.conf"
    
    info "Generating telegraf.env..."
    generate_env "$HOSTNAME" "$INFLUX_URL" "$INFLUX_ORG" "$INFLUX_BUCKET" "$INFLUX_TOKEN" > "$output_dir/telegraf.env"
    
    echo ""
    info "Files generated successfully in: $output_dir/"
    info "  - telegraf.conf"
    info "  - telegraf.env"
    echo ""
    warn "Remember to keep telegraf.env secure - it contains your InfluxDB token!"
}

# Live mode: Install files to /etc/telegraf/
live_mode() {
    info "Running in LIVE mode - installing to /etc/telegraf/"
    
    check_sudo
    
    # Ensure /etc/telegraf directory exists
    if [[ ! -d "/etc/telegraf" ]]; then
        warn "/etc/telegraf directory does not exist. Creating it..."
        sudo mkdir -p /etc/telegraf
    fi
    
    # Collect environment variables
    echo ""
    info "Please provide the following configuration:"
    echo ""
    
    local system_hostname=$(hostname)
    prompt_input "Hostname" "HOSTNAME" "$system_hostname" "false"
    
    prompt_input "InfluxDB URL" "INFLUX_URL" "" "true"
    prompt_input "InfluxDB Organization" "INFLUX_ORG" "" "true"
    prompt_input "InfluxDB Bucket" "INFLUX_BUCKET" "" "true"
    prompt_secret "InfluxDB Token" "INFLUX_TOKEN"
    
    # Backup existing files
    backup_file "/etc/telegraf/telegraf.conf"
    backup_file "/etc/telegraf/telegraf.env"
    
    # Generate and install files
    info "Generating telegraf.conf..."
    generate_config | sudo tee /etc/telegraf/telegraf.conf > /dev/null
    
    info "Generating telegraf.env..."
    generate_env "$HOSTNAME" "$INFLUX_URL" "$INFLUX_ORG" "$INFLUX_BUCKET" "$INFLUX_TOKEN" | sudo tee /etc/telegraf/telegraf.env > /dev/null
    
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
    echo "=========================================="
    echo "  Telegraf Setup Script"
    echo "  Mode: $MODE"
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
            error "Invalid mode: $MODE"
            exit 1
            ;;
    esac
    
    echo ""
    info "Setup complete!"
}

# Run main function
main
