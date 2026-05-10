

# Implementation Status

## Phase Completion Overview

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 0 | Create `qos-proxy` Go binary | ✅ Complete |
| Phase 1 | Update `qos-guard` to use proxy | ✅ Complete |
| Phase 2 | Update Makefile with proxy targets | ✅ Complete |
| Phase 3 | Update documentation | 🔄 In Progress |
| Phase 4 | Update tests | ⏳ Pending |
| Phase 5 | Add proxy health checks | ⏳ Pending |
| Phase 6 | Improve UDP limiting | ⏳ Pending |
| Phase 7 | Homebrew formula | ⏳ Pending |

## Completed Work

### Phase 0: qos-proxy Go Binary (Complete)

- Created [`qos-proxy/qos-proxy.go`](qos-proxy/qos-proxy.go) with:
  - HTTP/HTTPS proxy support
  - SOCKS5 proxy support
  - Token bucket rate limiting
  - CLI flags: `-b`/`--bind`, `-l`/`--limit`, `-p`/`--protocol`, `-v`/`--verbose`, `--pid`
- Build via: `cd qos-proxy && go build -o qos-proxy qos-proxy.go`

### Phase 1: qos-guard Update (Complete)

- Updated [`qos-guard`](qos-guard) to use proxy-based approach:
  - `find_proxy_binary()` — discovers qos-proxy from multiple locations
  - `start_proxy()` — launches qos-proxy with rate limit config
  - `stop_proxy()` — terminates proxy on exit
  - `set_proxy_env()` — sets `HTTPS_PROXY`, `HTTP_PROXY`, `all_proxy`
  - Removed broken pf PID matching code
  - Added `--proxy-port` flag for debugging

### Phase 2: Makefile Update (Complete)

- Updated [`Makefile`](Makefile) with proxy targets:
  - `proxy-build` — build qos-proxy
  - `proxy-install` — install to /usr/local/bin
  - `proxy-uninstall` — remove from /usr/local/bin
  - `proxy-cross` — cross-compile for amd64/arm64
  - `proxy-clean` — remove binary

### Phase 3: Documentation (In Progress)

- ✅ Updated [`README.md`](README.md) with proxy architecture
- 🔄 This file — implementation status update
- ⏳ Update `plans/architecture-fix-plan.md`

## Architecture Change Summary

| Aspect | Before (pf-based) | After (proxy-based) |
|--------|-------------------|---------------------|
| Limiting method | pf/dummynet pipes | Local proxy with token bucket |
| Per-PID matching | ❌ Broken (invalid pf syntax) | ✅ Works via proxy env vars |
| TCP limiting | Broken | ✅ Working |
| UDP limiting | Interface-level | Interface-level (best-effort) |
| Tools supported | All (theoretically) | Proxy-aware tools only |
| macOS compatibility | ❌ Broken on macOS 12+ | ✅ Works on macOS 12+ |

---


I see the tool restrictions in architect mode. Let me work with my knowledge of macOS to design this solution.

## Brainstorming: macOS CLI Bandwidth Limiter ("QoS Guard CLI")

### Core Problem Analysis

Your original idea targeted iOS, but you want to adapt it for **macOS (non-jailbroken)**. This is actually much more feasible since macOS has native networking controls that iOS lacks.

### Available macOS Native Mechanisms

macOS has several built-in tools for bandwidth limiting:

1. **`pf` (Packet Filter)** - macOS's built-in firewall with traffic shaping capabilities
2. **`dummynet`** - Works with `pf` to queue and shape traffic per-process
3. **`networksetup`** - For network configuration (less relevant for per-process limiting)
4. **`NEPacketTunnelProvider`** - NetworkExtension framework (overkill for a simple CLI)

### Recommended Approach: `pf` + `dummynet`

This is the **simplest, most reviewable, non-jailbroken solution**:

```
┌─────────────────────────────────────────────────────────┐
│                   QoS Guard CLI                         │
│                                                         │
│  qos-guard 50% ollama pull biglm                        │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────┐                                         │
│  │ 1. Detect     │──→ Get current bandwidth              │
│  │    bandwidth  │    (ifconfig en0)                     │
│  └──────────────┘                                         │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────┐                                         │
│  │ 2. Calculate  │──→ Convert % to kbps                  │
│  │    limits     │    (50% of 100Mbps = 50Mbps)          │
│  └──────────────┘                                         │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────┐                                         │
│  │ 3. Create     │──→ Generate pf rules                    │
│  │    pf rules   │    (dummynet pipe for process)          │
│  └──────────────┘                                         │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────┐                                         │
│  │ 4. Launch     │──→ Run command with process ID          │
│  │    command    │    tracking                             │
│  └──────────────┘                                         │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────┐                                         │
│  │ 5. Cleanup    │──→ Remove pf rules on exit            │
│  │    on exit    │    (trap SIGINT/SIGTERM)               │
│  └──────────────┘                                         │
└─────────────────────────────────────────────────────────┘
```

### How `pf` + `dummynet` Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Network Stack                            │
│                                                             │
│  ollama process ──→ pf filter ──→ dummynet pipe ──→ en0   │
│                    (match)      (throttle)       (WiFi/     │
│                                             Ethernet)       │
│                                                             │
│  pf rules example:                                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  | pipe 1 config (bandwidth: 50%)                      │   │
│  | map { en0 } → pipe 1                                │   │
│  | pass out on en0 route-to pflow1 any                │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Proposed CLI Interface

```
qos-guard <bandwidth_limit> <command> [args...]

Examples:
  qos-guard 50% ollama pull biglm          # 50% of available bandwidth
  qos-guard 10mbps curl https://example.com # Fixed 10 Mbps
  qos-guard 500kbps wget large-file.tar    # Fixed 500 Kbps
  qos-guard --restore                       # Clean up stale rules
```

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Tech** | `pf` + `dummynet` | Native to macOS, no installs needed |
| **Language** | Bash + `pfctl` | Simple, reviewable, no compilation |
| **Privilege** | `sudo` required | `pf` needs root |
| **Scope** | Per-process via `ipfw`/`pf` | Precise control |
| **Cleanup** | Signal traps | Auto-cleanup on exit |

### Implementation Plan

