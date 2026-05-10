# qos-guard v1.0.0 Release Notes

**Release Date:** 2026-05-10

**Status:** Stable

---

## Overview

qos-guard is a CLI tool for per-process bandwidth limiting on macOS. It uses a proxy-based approach with a Go-based rate-limiting proxy (`qos-proxy`) to control network throughput for any command.

---

## Feature Highlights

### Core Features

- **Proxy-Based Bandwidth Limiting**: Controls network bandwidth for any command via a local HTTP proxy
- **Multiple Bandwidth Formats**: Supports percentage (`50%`), megabits (`10mbps`), and kilobits (`500kbps`)
- **Automatic Interface Detection**: Detects the default network interface using `route get default` with fallbacks to `netstat` and common interfaces
- **Interface Bandwidth Auto-Detection**: Reads interface speed from `ifconfig` and converts percentage limits accordingly
- **Dry-Run Mode**: Preview actions without executing (`--dry-run`)

### Command-Line Options

| Flag | Description |
|------|-------------|
| `--restore` | Clean up stale proxy processes |
| `--help`, `-h` | Show help message |
| `--version` | Show version |
| `--verbose`, `-v` | Enable verbose output with timestamps |
| `--dry-run`, `-n` | Preview actions without executing |
| `--interface`, `-i IFACE` | Specify network interface (e.g., `en0`) |
| `--proxy-port PORT` | Use a specific proxy port (for debugging) |
| `--udp-interface`, `-u IFACE` | Interface for UDP traffic limiting (requires sudo) |

### Advanced Features

- **Signal Handling**: Graceful cleanup on SIGINT/SIGTERM
- **Child Process Tracking**: Tracks all descendant PIDs using `pgrep -P`
- **Idempotent Cleanup**: Prevents double-cleanup via `CLEANUP_DONE` flag
- **Proxy Binary Discovery**: Searches relative path, `/usr/local/bin`, `$HOME/.local/bin`, and `$PATH`

---

## Installation

### Prerequisites

- macOS 12+ (Monterey or later)
- Go 1.21+ (to build qos-proxy)
- `bc` (usually pre-installed on macOS)

### Quick Install

```bash
# Clone the repository
git clone https://github.com/alexcellier/qos-guard-cli.git
cd qos-guard-cli

# Build the proxy
cd qos-proxy && go build -o qos-proxy && cd ..

# Make qos-guard executable
chmod +x qos-guard

# Optional: Install to PATH
sudo cp qos-guard /usr/local/bin/qos-guard
sudo cp qos-proxy/qos-proxy /usr/local/bin/qos-proxy
```

### Homebrew Install

```bash
brew tap alexcellier/homebrew-qos-guard
brew install qos-guard
```

---

## Usage Examples

### Limit to a Percentage of Interface Speed

```bash
# Use 50% of your interface bandwidth
qos-guard 50% curl https://example.com

# Use 33.5% with verbose output
qos-guard --verbose 33.5% wget https://example.com/large-file.tar
```

### Limit to Absolute Speed

```bash
# Limit to 10 Mbps
qos-guard 10mbps curl https://example.com

# Limit to 500 kbps
qos-guard 500kbps wget https://example.com/small-file.tar

# Mixed case also works
qos-guard 10Mbps curl https://example.com
```

### Specify Interface

```bash
# Force use of en0 interface
qos-guard --interface en0 50% curl https://example.com

# Short flag
qos-guard -i en0 50% curl https://example.com
```

### Dry-Run Mode

```bash
# Preview what would happen
qos-guard --dry-run 50% curl https://example.com
# Output:
# [dry-run] Would detect interface...
# [dry-run] Detected interface: en0
# [dry-run] Detected bandwidth: 100 Mbps
# [dry-run] Calculated limit (50%): 50000 kbps
# [dry-run] Proxy: qos-proxy -b 127.0.0.1:XXXXX -l 50% -p all
# [dry-run] Would execute: curl https://example.com
```

### Custom Proxy Port

```bash
# Use port 8080 for debugging
qos-guard --proxy-port 8080 50% curl https://example.com
```

### Clean Up Stale Processes

```bash
qos-guard --restore
```

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    qos-guard                         │
│              (bash wrapper)                          │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│                   qos-proxy                          │
│            (Go rate-limiting proxy)                  │
│                                                      │
│  Sets HTTPS_PROXY, HTTP_PROXY, all_proxy             │
│  environment variables for target command            │
└─────────────────────────────────────────────────────┘
```

---

## Testing

```bash
# Run all tests
bats tests/

# Run integration tests only
bats tests/test-qos-guard.bats

# Run unit tests only
bats tests/unit-test-qos-guard.bats
```

**Test Coverage:** 154 tests (77 integration, 76 unit, 1 skip)

---

## Known Limitations

1. **TCP Only by Default**: The proxy approach only limits TCP traffic. UDP limiting requires `sudo` and uses `pfctl` with dummynet pipes.
2. **macOS Only**: Relies on macOS-specific tools (`ifconfig`, `route`, `lsof`, `pfctl`).
3. **Proxy Requirement**: The target command must respect HTTP proxy environment variables. Native TCP/UDP connections bypass the proxy.
4. **UDP Limiting Requires Sudo**: Interface-level UDP limiting uses `pfctl` which requires root privileges.
5. **Interface Bandwidth Detection**: If `ifconfig` doesn't report `media:.*<speed>bps`, defaults to 100 Mbps for percentage calculations.
6. **No IPv6 Support**: The proxy binds to `127.0.0.1` only.

---

## Troubleshooting

### "qos-proxy binary not found"

Ensure qos-proxy is built and in one of the searched locations:
- `./qos-proxy/qos-proxy` (relative to qos-guard)
- `/usr/local/bin/qos-proxy`
- `$HOME/.local/bin/qos-proxy`
- In `$PATH`

### "Could not detect a network interface"

Check your network connection:
```bash
route get default
ifconfig
```

### Stale Proxy Processes

Clean up manually:
```bash
qos-guard --restore
# Or manually:
pkill -f qos-proxy
```

---

## License

See [LICENSE](LICENSE) for details.

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
