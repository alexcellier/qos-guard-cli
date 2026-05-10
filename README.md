# QoS Guard CLI

A macOS command-line tool for per-process bandwidth limiting using a local proxy-based approach with [`qos-proxy`](qos-proxy/qos-proxy.go).

## Overview

QoS Guard allows you to limit the network bandwidth of any command running on your Mac. It works by starting a local rate-limiting proxy and routing the target command's traffic through it.

**Why proxy-based?** The previous version used macOS `pf` (Packet Filter) with `dummynet` pipes for per-process bandwidth limiting. However, macOS `pf` does not support per-PID matching in filter rules, making the approach non-functional. The new proxy-based approach uses a Go binary (`qos-proxy`) that intercepts HTTP/HTTPS/SOCKS traffic and applies token bucket rate limiting.

QoS Guard is useful for:

- Downloading large files without saturating your connection
- Running bandwidth-intensive operations (e.g., `ollama pull`, `git clone`, `docker pull`) without disrupting other work
- Enforcing strict bandwidth caps for compliance or cost reasons

## Architecture

### How It Works

```
┌──────────────────────────────────────────────────────────────┐
│                    QoS Guard CLI                              │
│                                                               │
│  qos-guard 50% curl https://example.com                      │
│         │                                                     │
│         ▼                                                     │
│  ┌──────────────┐                                            │
│  │ 1. Detect     │──→ Get current bandwidth                  │
│  │    bandwidth  │    (ifconfig en0)                         │
│  └──────────────┘                                            │
│         │                                                     │
│         ▼                                                     │
│  ┌──────────────┐                                            │
│  │ 2. Calculate  │──→ Convert % to kbps                      │
│  │    limits     │    (50% of 100Mbps = 50Mbps)              │
│  └──────────────┘                                            │
│         │                                                     │
│         ▼                                                     │
│  ┌──────────────┐                                            │
│  │ 3. Start      │──→ Launch qos-proxy with rate limit       │
│  │    proxy      │    (token bucket, port 0 = random)        │
│  └──────────────┘                                            │
│         │                                                     │
│         ▼                                                     │
│  ┌──────────────┐                                            │
│  │ 4. Set        │──→ HTTPS_PROXY, HTTP_PROXY,               │
│  │    proxy env  │    all_proxy = http://127.0.0.1:PORT      │
│  └──────────────┘                                            │
│         │                                                     │
│         ▼                                                     │
│  ┌──────────────┐                                            │
│  │ 5. Execute    │──→ Run command with proxy env vars        │
│  │    command    │    (curl, wget, git, etc.)                │
│  └──────────────┘                                            │
│         │                                                     │
│         ▼                                                     │
│  ┌──────────────┐                                            │
│  │ 6. Cleanup    │──→ Kill proxy, reset env vars on exit    │
│  │    on exit    │    (trap SIGINT/SIGTERM)                  │
│  └──────────────┘                                            │
│                                                               │
│  Traffic Flow:                                                │
│  Command → HTTPS_PROXY → qos-proxy → rate limiter → Internet │
└──────────────────────────────────────────────────────────────┘
```

### Proxy Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                  qos-proxy (Go Binary)                        │
│                                                               │
│  ┌─────────────┐  ┌─────────────┐                           │
│  │  HTTP/HTTPS │  │   SOCKS5    │                           │
│  │   Proxy     │  │   Proxy     │                           │
│  │  (port X)   │  │   (port Y)  │                           │
│  └──────┬──────┘  └──────┬──────┘                           │
│         │                 │                                  │
│         ▼                 ▼                                  │
│  ┌─────────────────────────────┐                            │
│  │   Token Bucket Rate Limiter │                            │
│  │   bw = ${LIMIT} Kbit/s      │                            │
│  └──────────────┬──────────────┘                            │
│                 │                                            │
│                 ▼                                            │
│  ┌─────────────────────────────┐                            │
│  │   Outbound Connection       │                            │
│  └──────────────┬──────────────┘                            │
│                 │                                            │
│                 ▼                                            │
│            ┌──────────────┐                                  │
│            │  Internet    │                                  │
│            └──────────────┘                                  │
└──────────────────────────────────────────────────────────────┘
```

## Installation

### Option 1: Install via Make

```bash
git clone https://github.com/alexcellier/qos-guard-cli.git
cd qos-guard-cli
make install
```

This installs both `qos-guard` and `qos-proxy` to `/usr/local/bin/`.

### Option 2: Manual Install

```bash
# Install qos-guard
cp qos-guard /usr/local/bin/qos-guard
chmod +x /usr/local/bin/qos-guard

# Build and install qos-proxy
cd qos-proxy
go build -o ../qos-proxy/qos-proxy qos-proxy.go
cd ..
cp qos-proxy/qos-proxy /usr/local/bin/qos-proxy
chmod +x /usr/local/bin/qos-proxy
```

### Option 3: Homebrew

```bash
brew tap alexcellier/homebrew-qos-guard
brew install qos-guard
```

## Prerequisites

- **macOS 12+** (Monterey or later)
- **sudo privileges** — required to bind to proxy ports and manage network settings
- **Go 1.21+** — required to build `qos-proxy` from source
- **curl or wget** — for testing bandwidth limits

## Usage

### Basic Syntax

```bash
sudo qos-guard <bandwidth_limit> <command> [args...]
```

### Arguments

| Argument | Description | Examples |
|----------|-------------|----------|
| `bandwidth_limit` | Bandwidth limit | `50%`, `10mbps`, `500kbps` |
| `command` | Command to execute | `curl`, `wget`, `ollama` |
| `args` | Command arguments | `https://example.com` |

### Bandwidth Limit Formats

| Format | Example | Description |
|--------|---------|-------------|
| Percentage | `50%` | 50% of detected interface bandwidth |
| Megabits | `10mbps` | 10 Mbps absolute limit |
| Kilobits | `500kbps` | 500 Kbps absolute limit |

### Examples

```bash
# Limit to 50% of available bandwidth
sudo qos-guard 50% curl https://example.com/large-file.zip

# Limit to 10 Mbps
sudo qos-guard 10mbps wget https://example.com/large-file.tar.gz

# Limit to 500 Kbps
sudo qos-guard 500kbps ollama pull biglm

# Use a specific network interface
sudo qos-guard --interface en0 10mbps git clone https://github.com/example/repo.git

# Use a custom proxy port (for debugging)
sudo qos-guard --proxy-port 8080 50% curl https://example.com

# Dry-run mode (preview without executing)
sudo qos-guard --dry-run 50% curl https://example.com

# Verbose mode (show detailed logs)
sudo qos-guard --verbose 50% curl https://example.com

# Clean up stale proxy processes
sudo qos-guard --restore
```

### Help

```bash
qos-guard --help
qos-guard --version
```

## Command Reference

### qos-guard Options

| Option | Description |
|--------|-------------|
| `--restore` | Clean up any stale proxy processes |
| `--help, -h` | Show help message |
| `--version` | Show version |
| `--verbose, -v` | Enable verbose output with timestamps |
| `--dry-run, -n` | Preview actions without executing |
| `--interface, -i IFACE` | Specify network interface (e.g., en0) |
| `--proxy-port PORT` | Use a specific proxy port (for debugging) |

### qos-proxy Options

| Option | Description |
|--------|-------------|
| `-b, --bind ADDR` | Bind address (default: `127.0.0.1:0`) |
| `-l, --limit LIMIT` | Bandwidth limit (e.g., `10000Kbit`) |
| `-p, --protocol PROTO` | Protocol: `http`, `https`, `socks5`, `all` (default: `all`) |
| `-v, --verbose` | Enable verbose logging |
| `--pid PID` | Target process ID (for monitoring) |

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make install` | Install qos-guard and qos-proxy to `/usr/local/bin` |
| `make uninstall` | Remove qos-guard from `/usr/local/bin` |
| `make proxy-build` | Build the qos-proxy binary |
| `make proxy-install` | Install qos-proxy to `/usr/local/bin` |
| `make proxy-uninstall` | Remove qos-proxy from `/usr/local/bin` |
| `make proxy-cross` | Cross-compile qos-proxy for macOS amd64/arm64 |
| `make proxy-clean` | Remove the qos-proxy binary |
| `make test` | Run BATS test suite |
| `make lint` | Lint the script with shellcheck |
| `make clean` | Remove temporary files |
| `make help` | Show available targets |

## Supported Tools

QoS Guard works with any tool that respects the standard proxy environment variables:

| Tool | Proxy Support | How |
|------|---------------|-----|
| `curl` | Built-in | `HTTPS_PROXY` env var |
| `wget` | Built-in | `https_proxy` env var |
| `git` | Built-in | `https_proxy` env var |
| `npm` | Built-in | `https_proxy` env var |
| `pip`/`pip3` | Built-in | `https_proxy` env var |
| `docker` | Partial | May need `--proxy` flag |
| `ollama` | Partial | May need `all_proxy` |

## Limitations

### Proxy-Aware Only

QoS Guard limits traffic by setting proxy environment variables (`HTTPS_PROXY`, `HTTP_PROXY`, `all_proxy`). Only tools that respect these environment variables will be rate-limited.

### UDP Traffic

UDP traffic cannot be limited per-process via proxy. The proxy only handles TCP connections (HTTP/HTTPS/SOCKS5).

### Non-Proxy Tools

Tools without proxy support (e.g., `ssh`, `scp`, custom TCP applications) will bypass the bandwidth limit. Workarounds:

- For `ssh`: Use `ProxyCommand` with a SOCKS proxy
- For custom apps: Configure them to use the proxy

### sudo Required

`qos-guard` requires `sudo` because it may need root privileges to bind to proxy ports.

### macOS 12+ Only

The tool requires macOS 12 (Monterey) or later for full compatibility with network detection APIs.

## Troubleshooting

### "sudo is required"

QoS Guard requires `sudo` because managing proxy ports may require root privileges:

```bash
sudo qos-guard 50% curl https://example.com
```

### "Could not detect a network interface"

Make sure your network is connected. If you have multiple interfaces, you can try:

```bash
# Check which interface is active
route get default

# Manually verify ifconfig works
ifconfig en0
```

### "qos-proxy binary not found"

Ensure `qos-proxy` is built and installed:

```bash
# Build from source
cd qos-proxy && go build -o qos-proxy qos-proxy.go && cd ..

# Or install via Makefile
make proxy-install
```

### "Failed to get proxy port"

This may occur if the proxy fails to start. Check:

1. Is the port already in use? Try `--proxy-port` with a different port.
2. Do you have sudo privileges? Binding to low ports requires root.
3. Check verbose output: `sudo qos-guard --verbose 50% curl https://example.com`

### Stale proxy processes remaining

If proxy processes aren't cleaned up (e.g., after a crash), run:

```bash
sudo qos-guard --restore
```

### Verifying the proxy is working

Use verbose mode to see proxy details:

```bash
sudo qos-guard --verbose 50% curl -I https://example.com
```

You should see output like:

```
[2024-01-01 12:00:00] Starting proxy with limit: 50000 kbps
[2024-01-01 12:00:00] Proxy started on port 51234 (PID: 12345)
[2024-01-01 12:00:00] Set proxy env vars: HTTPS_PROXY=http://127.0.0.1:51234
```

## Development

### Running Tests

```bash
brew install bats-core  # If not installed
make test
```

### Linting

```bash
brew install shellcheck  # If not installed
make lint
```

### Building qos-proxy

```bash
# Build for current architecture
make proxy-build

# Cross-compile for macOS amd64 and arm64
make proxy-cross
```

### Uninstall

```bash
make uninstall
```

## License

MIT
