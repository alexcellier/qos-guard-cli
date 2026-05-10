# QoS Guard CLI Installation Guide

## Overview

QoS Guard CLI consists of two components:

- **qos-guard** — A shell script CLI tool for per-process bandwidth limiting
- **qos-proxy** — A Go binary that provides HTTP/HTTPS/SOCKS5 proxy with rate limiting

## Homebrew Installation

### Prerequisites

- macOS 12+ (Monterey or later)
- Homebrew installed ([https://brew.sh](https://brew.sh))
- Go 1.21+ (required to build qos-proxy from source)

### From Homebrew Tap (Custom Tap)

```bash
brew tap alexcellier/homebrew-qos-guard
brew install qos-guard
```

> **Note:** The homebrew-core submission is pending approval. Once approved, installation will be:
> ```bash
> brew install qos-guard
> ```

### From Source (Development)

```bash
# Install Go if not already installed
brew install go

# Clone the repository
git clone https://github.com/alexcellier/qos-guard-cli.git
cd qos-guard-cli

# Install from local formula
brew install ./Formula/qos-guard.rb
```

### Build from Source Manually

```bash
# Install qos-guard (shell script)
cp qos-guard /usr/local/bin/qos-guard
chmod +x /usr/local/bin/qos-guard

# Build qos-proxy
cd qos-proxy
go build -o qos-proxy
cp qos-proxy /usr/local/bin/qos-proxy
```

## Verification

```bash
# Check qos-guard version
qos-guard --version

# Check qos-proxy is installed
qos-proxy --help
```

## Known Limitations

- **macOS only** — qos-guard uses macOS-specific tools (`pfctl`, `ifconfig`, `route`)
- Requires sudo privileges for UDP interface-level limiting
- qos-proxy requires Go 1.21+ to build

## Uninstall

```bash
brew uninstall qos-guard
```
