# Telegraf Wire

A lightweight, optimized Telegraf setup script for quick deployment on Linux hosts. Generates Telegraf configuration with versioned measurement names and optimized collection intervals.

## Features

- **Two run modes**: Pack (generate configs) or Live (install on host)
- **Optimized collection intervals**:
  - CPU: Every 2 minutes
  - Memory: Every 5 minutes
  - Disk: Hourly
  - System: Every 5 minutes
- **Versioned measurement names** (v2_ prefix) for easy migration
- **Interactive setup** with validation
- **Safe defaults** with minimal data collection

## Quick Start

### Pack Mode (Default)

Generate configuration files in a timestamped output folder:

```bash
curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/main/scripts/setup-telegraf.sh | bash
```

Or download and run locally:

```bash
./scripts/setup-telegraf.sh pack
```

This creates an `output_YYMMDD_HHMMSS/` folder containing:
- `telegraf.conf` - Telegraf configuration
- `telegraf.env` - Environment variables (keep secure!)

### Live Mode

Install and configure Telegraf directly on the current host (requires sudo):

```bash
curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/main/scripts/setup-telegraf.sh | bash -s live
```

Or download and run locally:

```bash
./scripts/setup-telegraf.sh live
```

This will:
- Backup existing `/etc/telegraf/telegraf.conf` and `/etc/telegraf/telegraf.env` (if they exist)
- Install new configuration files
- Set proper file permissions

After installation, restart Telegraf:

```bash
sudo systemctl restart telegraf
sudo systemctl status telegraf
```

## Configuration

The script will prompt you for:

- **Hostname** (optional, defaults to system hostname)
- **InfluxDB URL** (required)
- **InfluxDB Organization** (required)
- **InfluxDB Bucket** (required)
- **InfluxDB Token** (required, hidden input)

## Measurement Naming Strategy

All measurements use versioned names with the `v2_` prefix:

- `cpu` → `v2_cpu`
- `mem` → `v2_mem`
- `disk` → `v2_disk`
- `system` → `v2_system`

This allows for easy migration to new measurement structures in the future (e.g., `v3_*`) while maintaining backward compatibility. Related metrics are kept in separate measurements as per Telegraf defaults, but with versioned names for future flexibility.

## Collection Intervals

Optimized for efficiency and low data usage:

| Metric | Interval | Rationale |
|--------|----------|-----------|
| CPU | 120s (2 min) | Frequently changing, needs regular monitoring |
| Memory | 300s (5 min) | Changes less frequently than CPU |
| System | 300s (5 min) | General system metrics |
| Disk | 3600s (1 hour) | Changes slowly, hourly is sufficient |

## Generated Configuration

The script generates a minimal but effective Telegraf configuration:

- **Agent settings**: Optimized batching and buffering
- **CPU input**: Total CPU only, active reporting
- **Memory input**: Available memory metrics only
- **Disk input**: Excludes tmpfs, devtmpfs, and other virtual filesystems
- **System input**: Basic system metrics
- **Rename processors**: Version all measurement names
- **InfluxDB v2 output**: Configured with environment variables

## Security Notes

- The `telegraf.env` file contains your InfluxDB token - keep it secure!
- In live mode, `telegraf.env` is set to mode 600 (owner read/write only)
- The script never hardcodes secrets - all values are collected interactively
- `.gitignore` excludes `telegraf.env` and backup files from version control

## File Structure

```
/etc/telegraf/dev/
├── scripts/
│   └── setup-telegraf.sh
├── .gitignore
└── README.md
```

## Usage Examples

### Generate configs for multiple hosts

```bash
# Generate configs without modifying current system
./scripts/setup-telegraf.sh pack
# Repeat for each host, then copy output_*/ folders to target hosts
```

### Quick setup on new host

```bash
# One command to install and configure
curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/main/scripts/setup-telegraf.sh | bash -s live
```

## Troubleshooting

### Permission denied in live mode

Ensure you have sudo access:

```bash
sudo -v
```

### Telegraf service not found

Install Telegraf first:

```bash
# Ubuntu/Debian
sudo apt-get update && sudo apt-get install telegraf

# RHEL/CentOS
sudo yum install telegraf
```

### Configuration not loading

Check that environment variables are loaded:

```bash
# Telegraf should source telegraf.env automatically
# Verify with:
sudo telegraf --config /etc/telegraf/telegraf.conf --test
```

## License

This script is provided as-is for use in setting up Telegraf configurations.
