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
- **Modern Bash 5.2+** with enhanced security and error handling
- **Comprehensive help system** with `--help`, `--local`, and `--version` flags

## Requirements

- **Bash 5.2 or greater** (required for script execution - Ubuntu 24.04 includes 5.2.21)
- **sudo access** (for live/--local mode)
- **Telegraf** (for live/--local mode - installation instructions provided in pack mode)

### Installing Bash 5.2+ (if needed)

If your system doesn't have Bash 5.2+, you can install it from apt repositories:

**Install Bash from apt (Ubuntu/Debian):**
```bash
sudo apt-get update
sudo apt-get install bash
```

**Verify your Bash version:**
```bash
bash --version
```

Most modern Ubuntu systems (20.04+) come with Bash 5.2+ pre-installed, so no additional installation is typically needed.

## Quick Start

### Pack Mode (Default)

Generate configuration files in a timestamped output folder:

```bash
curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/trunk/scripts/setup-telegraf.sh | bash
```

Or download and run locally:

```bash
./scripts/setup-telegraf.sh pack
# or simply:
./scripts/setup-telegraf.sh
```

This creates an `output_YYMMDD_HHMMSS/` folder containing:
- `telegraf.conf` - Telegraf configuration
- `telegraf.env` - Environment variables (keep secure!)

After generation, the script displays complete Telegraf installation instructions for using the generated files.

### Live Mode (--local)

Install and configure Telegraf directly on the current host (requires sudo):

```bash
curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/trunk/scripts/setup-telegraf.sh | bash -s -- --local
```

Or download and run locally:

```bash
./scripts/setup-telegraf.sh --local
# or:
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
│   └── setup-telegraf.sh    # Main Telegraf setup script (requires Bash 5.2+)
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
curl -sSL https://raw.githubusercontent.com/sheeriot/telegraf-wire/trunk/scripts/setup-telegraf.sh | bash -s live
```

## Command Line Options

The setup script supports several options:

```bash
./scripts/setup-telegraf.sh [OPTIONS] [MODE]

Options:
  -h, --help      Show comprehensive help message
  -v, --version   Show version information

Modes:
  pack (default)  Generate configuration files in timestamped folder
  live, --local   Install configuration directly to /etc/telegraf/
```

**Examples:**
```bash
# Show help
./scripts/setup-telegraf.sh --help

# Show version
./scripts/setup-telegraf.sh --version

# Generate configs (default)
./scripts/setup-telegraf.sh
./scripts/setup-telegraf.sh pack

# Install locally
./scripts/setup-telegraf.sh --local
./scripts/setup-telegraf.sh live
```

## Troubleshooting

### Bash version too old

If you see an error about Bash 5.2+ being required:

```bash
# Check your current version
bash --version

# Install Bash from apt (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install bash

# Verify installation
bash --version
```

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

## Design Philosophy & Rationale

### Why Versioned Measurement Names?

Using versioned measurement names (e.g., `v2_cpu`, `v3_cpu`) provides several benefits:

1. **Easy Migration**: When you need to change measurement structure, you can create `v3_*` measurements without breaking existing queries or dashboards that use `v2_*`
2. **A/B Testing**: Run both versions simultaneously during migration to compare data quality
3. **Rollback Capability**: If new structure has issues, you can quickly switch back to previous version
4. **Consistency**: Matches the pattern used in SensorPlaces app (e.g., `v2_wind`, `v3_wind`)

### Why Different Collection Intervals?

Metrics are collected at different intervals based on their change frequency and monitoring needs:

- **CPU (2 min)**: Changes frequently, needs near-real-time monitoring for performance issues
- **Memory/System (5 min)**: Changes less frequently, 5-minute intervals provide good balance between data freshness and storage efficiency
- **Disk (1 hour)**: Changes very slowly, hourly collection is sufficient and significantly reduces data volume

This approach minimizes data storage costs while maintaining adequate monitoring granularity.

### Why Separate Measurements?

Related metrics (like temperature and humidity, or wind speed and wind chill) should be grouped together in the same measurement. However, for system metrics, we keep them separate (CPU, memory, disk, system) because:

- They have different collection intervals
- They serve different monitoring purposes
- Telegraf's default structure already separates them
- Versioning allows future restructuring if needed

### Agent Configuration Choices

- **Base interval (60s)**: Minimum interval for inputs that don't specify their own
- **Batch size (1000)**: Balances network efficiency with memory usage
- **Buffer limit (3000)**: Allows temporary network outages without data loss
- **Precision (1s)**: Sufficient for system metrics, reduces timestamp storage overhead

## Implementation Details

### How the Script Works

1. **Version Check**: Verifies Bash 5.2+ is available
2. **Web Execution Detection**: Warns if running from pipe (curl | bash)
3. **Mode Detection**: Script accepts `pack`, `live`, `--local`, or flags like `--help`
4. **Input Collection**: Interactive prompts with validation (URLs, hostnames, identifiers)
5. **Input Sanitization**: All inputs are sanitized to prevent code injection
6. **Config Generation**: Uses heredoc to generate `telegraf.conf` with all optimizations
7. **Environment File**: Creates `telegraf.env` with safely quoted variables
8. **File Installation** (live mode only):
   - Backs up existing files with timestamped `.bak` extension
   - Writes new files with proper permissions (644 for conf, 600 for env)
9. **Installation Instructions**: Pack mode displays complete Telegraf setup guide

### Measurement Renaming

The script uses Telegraf's `processors.rename` plugin to version measurement names:

```toml
[[processors.rename]]
  [[processors.rename.replace]]
    measurement = "cpu"
    dest = "v2_cpu"
```

This happens after data collection but before sending to InfluxDB, ensuring all metrics are properly versioned.

### Environment Variable Usage

Telegraf automatically loads environment variables from `/etc/telegraf/telegraf.env` (or uses system environment). The config file references them using `${VARIABLE_NAME}` syntax, keeping secrets out of the configuration file itself.

## Integration with SensorPlaces

This Telegraf setup complements the SensorPlaces application:

- **Consistent Naming**: Both use `v2_*` prefix for measurements
- **Same InfluxDB Bucket**: Can share the same bucket or use separate buckets
- **Migration Strategy**: Both can migrate to `v3_*` simultaneously when needed
- **Measurement Grouping**: SensorPlaces groups related metrics (wind speed + wind chill), while Telegraf keeps system metrics separate due to different collection intervals

## Migration Strategy

When ready to migrate to `v3_*` measurements:

1. Update the script to generate `v3_*` measurement names
2. Deploy new configuration (old `v2_*` data remains in database)
3. Update dashboards/queries to use `v3_*` measurements
4. Keep `v2_*` data for historical reference
5. Optionally archive or delete `v2_*` data after retention period

## Best Practices

1. **Use Pack Mode First**: Generate configs in pack mode, review them, then deploy manually or use live mode
2. **Test Configuration**: Always test generated configs with `telegraf --config telegraf.conf --test` before deploying
3. **Backup Before Live Mode**: The script backs up automatically, but consider manual backups for critical systems
4. **Secure Environment Files**: Never commit `telegraf.env` to version control (already in `.gitignore`)
5. **Monitor Data Volume**: Check InfluxDB data retention policies to avoid unexpected storage costs
6. **Version Control**: Keep track of which hosts are using which measurement version

## Advanced Usage

### Customizing Collection Intervals

To modify intervals, edit the `generate_config()` function in `setup-telegraf.sh`:

```bash
# Change CPU interval to 60s
[[inputs.cpu]]
  interval = "60s"  # Changed from 120s
```

### Adding Additional Inputs

To add more Telegraf inputs (e.g., network, processes), add them to the `generate_config()` function before the rename processors.

### Using Different Measurement Versions

To generate `v3_*` measurements, update all `dest = "v2_*"` lines in the rename processors to `dest = "v3_*"`.

## License

This script is provided as-is for use in setting up Telegraf configurations.
