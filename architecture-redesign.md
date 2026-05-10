# Architecture Redesign: QoS Guard CLI — Per-Process Bandwidth Limiting on macOS

## 1. Problem Statement

The current implementation of [`qos-guard`](qos-guard) has a **critical architectural flaw**: macOS `pf` (Packet Filter) does **not** support per-PID matching in filter rules. The rule syntax `from ${target_pid}` is invalid and silently fails.

```
# CURRENT (BROKEN) — This does NOT work on macOS:
pass out on en0 inet from 12345 to any route-to pflow1001
#                                                        ^^^^^^^
#                                                        Invalid! pf has no PID matching

# WHAT WE NEED (conceptually):
pass out on en0 inet from <pid:12345> to any dummynet to pipe1001
#                                                        ^^^^^^^^
#                                                        This syntax doesn't exist in macOS pf
```

This means **no traffic is actually being limited** — the pipe is created but nothing routes through it.

---

## 2. macOS Per-Process Bandwidth Limiting Landscape

### 2.1 Available Mechanisms

| Mechanism | Per-Process | Per-Protocol | macOS Version | Entitlements | Complexity |
|-----------|-------------|--------------|---------------|--------------|------------|
| **ipfw** (deprecated) | UID-based | TCP/UDP | ≤ 10.11 | No | Low |
| **pf + dummynet** | ❌ No | Interface-wide | All | No | Medium |
| **pf + rdr + proxy** | ✅ Yes (TCP) | TCP only | All | No | Medium |
| **NetworkExtension** | ✅ Yes | TCP/UDP | 10.10+ | Yes | High |
| **TUN/TAP** | ✅ Yes | TCP/UDP | All | Yes | High |
| **NEPacketFlowProvider** | ✅ Yes | TCP/UDP | 10.11+ | Yes | High |

### 2.2 Why ipfw Doesn't Work

```
macOS 10.8 (Mountain Lion) — ipfw deprecated
macOS 10.11 (El Capitan) — ipfw removed
macOS 12+ (Monterey+) — ipfw completely unavailable
```

The `ipfw pipe` command supported per-UID matching:
```bash
# This USED to work (macOS 10.7 and earlier):
ipfw add 100 pipe 1 uid $USER
```

But this was removed in macOS 10.11 and is **completely unavailable** on macOS 12+.

### 2.3 Why NetworkExtension Doesn't Work for a CLI Tool

```
NEPacketTunnelProvider requires:
1. Code signing with NetworkExtension entitlement
2. App ID with NE capability
3. Distribution via App Store or enterprise provisioning
4. User must authorize the extension in System Preferences
5. Cannot be a simple CLI binary distributed on GitHub
```

This makes NetworkExtension unsuitable for a lightweight CLI tool.

---

## 3. Recommended Architecture: pf + rdr + Local Proxy

### 3.1 Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        qos-guard (Bash)                             │
│                                                                     │
│  1. Parse arguments & validate                                      │
│  2. Detect interface & bandwidth                                    │
│  3. Calculate limit                                                 │
│  4. Create pf rdr rules (redirect to local port)                    │
│  5. Launch local proxy (compiled Go/C helper)                       │
│  6. Execute target command                                          │
│  7. Cleanup on exit                                                 │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Network Stack (macOS)                           │
│                                                                     │
│  Target Process ──→ TCP connection ──→ pf rdr ──→ localhost:PORT   │
│                                                                        │
│  pf rule: pass in on en0 inet proto tcp from any to any port 443   │
│           rdr proto tcp to any port 443 -> 127.0.0.1 port 55555    │
│                                                                        │
│  Local Proxy ──→ Bandwidth limiter (token bucket) ──→ Forward to    │
│                 destination (with original IP/Port)                   │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  dummynet pipe (for UDP fallback)                           │   │
│  │  pipe qosguard-1001 config bw 50000Kbit                     │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 Component Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                         qos-guard CLI                                │
│                                                                      │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐               │
│  │  Argument   │──→│  Bandwidth  │──→│   pf Rules  │               │
│  │   Parser    │   │  Detector   │   │  Generator  │               │
│  └─────────────┘   └─────────────┘   └──────┬──────┘               │
│                                              │                       │
│  ┌─────────────┐   ┌─────────────┐   ┌──────▼──────┐               │
│  │   Signal    │   │   Cleanup   │   │   Proxy     │               │
│  │    Trap     │   │   Manager   │   │  Launcher   │               │
│  └─────────────┘   └─────────────┘   └──────┬──────┘               │
│                                              │                       │
│  ┌─────────────────────────────────────────────────────┐            │
│  │              Command Executor                       │            │
│  │  (launches target command with proxy config)       │            │
│  └─────────────────────────────────────────────────────┘            │
└──────────────────────────────────────────────────────────────────────┘
                              │              │
                              ▼              ▼
┌─────────────────────┐   ┌──────────────────────────┐
│  Target Command     │   │  Local Proxy (qos-proxy) │
│                     │   │                          │
│  curl https://...   │   │  ┌────────────────────┐  │
│  ollama pull ...    │   │  │ Token Bucket       │  │
│  wget ...           │   │  │ Rate Limiter       │  │
│                     │   │  │                    │  │
│  (TCP traffic)      │   │  │ In:  localhost     │  │
│  (UDP traffic)      │   │  │ Out: destination   │  │
│                     │   │  │ BW:  ${LIMIT}Kbit  │  │
│                     │   │  └────────────────────┘  │
└─────────────────────┘   └──────────────────────────┘
                              │
                              ▼
                      ┌──────────────┐
                      │  Internet    │
                      └──────────────┘
```

---

## 4. Detailed Design

### 4.1 Architecture Components

#### Component 1: qos-guard (Bash CLI) — Unchanged Core

The Bash CLI remains the user-facing interface. Changes:

| Change | Description |
|--------|-------------|
| **pf rules** | Use `rdr` (redirect) instead of invalid PID matching |
| **Proxy config** | Pass proxy port and limit to the helper |
| **Proxy launch** | Launch the compiled proxy helper |
| **Cleanup** | Kill proxy on exit, remove pf rules |

#### Component 2: qos-proxy (Go Binary) — New

A small compiled helper that:
- Listens on a local port
- Accepts redirected TCP connections
- Applies bandwidth limiting via token bucket algorithm
- Forwards traffic to the original destination
- Cleans up on signal

**Why Go?**
- Single static binary, no runtime dependencies
- Cross-compilable for multiple architectures (amd64, arm64)
- Built-in token bucket (`golang.org/x/time/rate`)
- Can be embedded in the Bash script via `embed` or distributed separately

**Alternative: C implementation**
- Smaller binary size
- No dependency management
- But harder to compile cross-platform

#### Component 3: pf Rules — Changed

```bash
# OLD (BROKEN):
# pass out on en0 inet from 12345 to any route-to pflow1001

# NEW (WORKING):
# 1. Create anchor
pfctl -a "qosguard" -N anchor 2>/dev/null || true

# 2. Redirect TCP traffic from target process to local proxy port
#    We use the process's source port to identify its traffic
#    (since pf can't match by PID, we match by source port)

# 3. Configure dummynet pipe
pfctl -a "qosguard" -p pipe qosguard-${PIPE_ID} config bw ${LIMIT_KBPS}Kbit

# 4. Apply rdr rule
echo "rdr pass out on ${INTERFACE} proto tcp from any to any port 80 -> 127.0.0.1 port ${PROXY_PORT}" > /tmp/qosguard.pf
echo "rdr pass out on ${INTERFACE} proto tcp from any to any port 443 -> 127.0.0.1 port ${PROXY_PORT}" >> /tmp/qosguard.pf
pfctl -a "qosguard" -f /tmp/qosguard.pf
```

**CRITICAL ISSUE:** Even with `rdr`, we still can't match by PID. We need a different approach.

### 4.2 Revised Approach: SOCKS Proxy with iptables-style matching

Since we can't match by PID in pf, we use a **SOCKS proxy** approach:

```
┌──────────────────────────────────────────────────────────────┐
│                    Revised Architecture                       │
│                                                               │
│  Target Command (with proxy env vars)                        │
│  ┌─────────────────────────────────────┐                     │
│  │ HTTPS_PROXY=http://127.0.0.1:55555 │                     │
│  │ HTTP_PROXY=http://127.0.0.1:55555  │                     │
│  │ all_proxy=socks5://127.0.0.1:55556 │                     │
│  └──────────────┬──────────────────────┘                     │
│                 │                                              │
│                 ▼                                              │
│  ┌─────────────────────────────────────┐                     │
│  │  Local Proxy (qos-proxy)            │                     │
│  │                                     │                     │
│  │  ┌─────────────┐  ┌─────────────┐  │                     │
│  │  │  HTTP/HTTPS │  │   SOCKS5    │  │                     │
│  │  │   Proxy     │  │   Proxy     │  │                     │
│  │  │  (port 55555)│ │ (port 55556)│  │                     │
│  │  └──────┬──────┘  └──────┬──────┘  │                     │
│  │         │                 │         │                     │
│  │         ▼                 ▼         │                     │
│  │  ┌─────────────────────────────┐    │                     │
│  │  │   Token Bucket Rate Limiter │    │                     │
│  │  │   bw = ${LIMIT_KBPS} Kbit/s │    │                     │
│  │  └──────────────┬──────────────┘    │                     │
│  │                 │                   │                     │
│  │                 ▼                   │                     │
│  │  ┌─────────────────────────────┐    │                     │
│  │  │   dummynet pipe (UDP)       │    │                     │
│  │  │   pipe qosguard-1001        │    │                     │
│  │  │   config bw ${LIMIT_KBPS}Kbit│    │                     │
│  │  └──────────────┬──────────────┘    │                     │
│  └─────────────────┼───────────────────┘                     │
│                    │                                           │
│                    ▼                                           │
│            ┌──────────────┐                                   │
│            │  Internet    │                                   │
│            └──────────────┘                                   │
└──────────────────────────────────────────────────────────────┘
```

**How it works:**
1. `qos-guard` sets `HTTPS_PROXY`, `HTTP_PROXY`, and `all_proxy` environment variables
2. The target command routes all HTTP/HTTPS/SOCKS traffic through the local proxy
3. `qos-proxy` applies bandwidth limiting before forwarding
4. Non-proxy-aware traffic is NOT limited (documented limitation)

### 4.3 Proxy Implementation Design

```go
// qos-proxy/main.go — Conceptual design

package main

import (
    "context"
    "fmt"
    "io"
    "net"
    "net/http"
    "os"
    "os/signal"
    "sync"
    "syscall"
    "time"

    "golang.org/x/time/rate"
)

type ProxyConfig struct {
    HTTPPort   int
    SOCKSPort  int
    LimitKbps  int
    PipeID     string
}

type RateLimitedProxy struct {
    limiter *rate.Limiter
    config  ProxyConfig
}

func NewRateLimitedProxy(cfg ProxyConfig) *RateLimitedProxy {
    // Convert Kbps to bytes per second for token bucket
    bytesPerSec := cfg.LimitKbps * 1000 / 8
    return &RateLimitedProxy{
        limiter: rate.NewLimiter(rate.Limit(bytesPerSec), bytesPerSec*2),
        config:  cfg,
    }
}

// HTTP/HTTPS proxy handler
func (p *RateLimitedProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    // Apply rate limit before forwarding
    if !p.limiter.Allow() {
        // Token bucket naturally throttles — no need for explicit wait
        time.Sleep(time.Millisecond)
    }
    
    // Forward request to original destination
    // ... (proxy logic)
}

// SOCKS5 proxy handler
func (p *RateLimitedProxy) ServeSOCKS(conn net.Conn) {
    defer conn.Close()
    
    // Parse SOCKS5 request
    // ... (SOCKS5 logic)
    
    // Connect to destination
    dst, err := net.Dial("tcp", destAddr)
    if err != nil {
        return
    }
    defer dst.Close()
    
    // Rate-limited copy in both directions
    var wg sync.WaitGroup
    wg.Add(2)
    
    go func() {
        defer wg.Done()
        p.limitedCopy(conn, dst)
    }()
    
    go func() {
        defer wg.Done()
        p.limitedCopy(dst, conn)
    }()
    
    wg.Wait()
}

// limitedCopy copies data with rate limiting
func (p *RateLimitedProxy) limitedCopy(dst io.Writer, src io.Reader) {
    buf := make([]byte, 32*1024) // 32KB buffer
    for {
        n, err := src.Read(buf)
        if n > 0 {
            // Wait for rate limiter tokens
            p.limiter.WaitN(context.Background(), n)
            dst.Write(buf[:n])
        }
        if err != nil {
            return
        }
    }
}

func main() {
    // Parse config from command line or environment
    httpPort := os.Getenv("QOS_HTTP_PORT")
    socksPort := os.Getenv("QOS_SOCKS_PORT")
    limitKbps := os.Getenv("QOS_LIMIT_KBPS")
    
    proxy := NewRateLimitedProxy(ProxyConfig{
        HTTPPort:  httpPort,
        SOCKSPort: socksPort,
        LimitKbps: limitKbps,
    })
    
    // Setup signal handling for cleanup
    sigChan := make(chan os.Signal, 1)
    signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
    
    // Start HTTP proxy
    go func() {
        http.ListenAndServe(fmt.Sprintf("127.0.0.1:%s", httpPort), proxy)
    }()
    
    // Start SOCKS5 proxy
    ln, _ := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%s", socksPort))
    go proxy.ServeSOCKS(ln.Accept())
    
    // Wait for signal
    <-sigChan
}
```

---

## 5. Alternative Approaches (Evaluated)

### 5.1 Approach: Interface-Level UDP Limiting (Simpler)

For UDP traffic that can't use a proxy, apply interface-level limiting:

```bash
# Create dummynet pipe
pfctl -a qosguard -p pipe qosguard-${PIPE_ID} config bw ${LIMIT_KBPS}Kbit

# Apply to ALL traffic on interface (not per-process)
# This is a best-effort approach
pfctl -a qosguard -F all 2>/dev/null || true
echo "dummynet all out on ${INTERFACE} pipe qosguard-${PIPE_ID}" | pfctl -a qosguard -f -
```

**Pros:**
- Actually works on macOS
- No compiled helper needed
- Simple Bash-only implementation

**Cons:**
- Limits ALL traffic on the interface, not just the target process
- Imprecise — other apps are affected
- Not true per-process limiting

### 5.2 Approach: Use `tc` via Linux Subsystem (WSL)

Not applicable — macOS doesn't have `tc` (Linux traffic control).

### 5.3 Approach: Compile a Small C Helper with `setsockopt`

```c
// Conceptual C helper
#include <sys/socket.h>
#include <netinet/in.h>

// Use SO_PRIORITY or custom socket options
// macOS doesn't expose per-socket bandwidth control via setsockopt
// This would require a kernel extension
```

**Verdict:** Not possible without a kernel extension.

---

## 6. Recommended Implementation Plan

### Phase 0: Architecture Fix (NEW)

| # | Task | Description |
|---|------|-------------|
| 0.1 | Create `qos-proxy` in Go | HTTP/HTTPS/SOCKS5 proxy with token bucket rate limiting |
| 0.2 | Cross-compile for amd64/arm64 | Build binaries for both architectures |
| 0.3 | Embed binary in qos-guard | Use `go:embed` or include in Makefile build |
| 0.4 | Update pf rules to use rdr | Replace broken PID rules with working rdr rules |
| 0.5 | Update CLI to set proxy env vars | `HTTPS_PROXY`, `HTTP_PROXY`, `all_proxy` |

### Phase 1: Foundation (Existing)

Keep as-is — argument parsing, validation, interface detection.

### Phase 2: Reliability (Existing)

Keep as-is — signal handling, verbose logging, dry-run mode.

### Phase 3: Polish & Distribution (Existing)

Add:
- `qos-proxy` binary distribution
- Architecture detection in install script
- Updated documentation

---

## 7. Updated CLI Interface

```bash
# TCP traffic (via proxy env vars)
sudo qos-guard 50% curl https://example.com
sudo qos-guard 10mbps wget https://example.com/file
sudo qos-guard 500kbps ollama pull biglm

# UDP traffic (interface-level, best-effort)
sudo qos-guard --udp-interface en0 500kbps some-udp-app

# Dry-run
qos-guard --dry-run 50% curl https://example.com

# Restore
sudo qos-guard --restore

# Help
qos-guard --help
```

---

## 8. Limitations & Documentation

### Documented Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| **Proxy-aware only** | Only HTTP/HTTPS/SOCKS traffic is limited | Document which tools support proxy env vars |
| **UDP not per-process** | UDP uses interface-level limiting | Document clearly; offer `--udp-interface` flag |
| **Non-proxy tools** | Tools without proxy support bypass limits | Document workarounds (e.g., `proxychains`) |
| **sudo required** | pf rules and proxy binding need root | Document clearly |
| **macOS 12+ only** | ipfw unavailable on older macOS | Minimum requirement documented |

### Tools That Work (with proxy support)

| Tool | Proxy Support | How |
|------|---------------|-----|
| `curl` | ✅ Built-in | `HTTPS_PROXY` env var |
| `wget` | ✅ Built-in | `https_proxy` env var |
| `git` | ✅ Built-in | `https_proxy` env var |
| `ollama` | ⚠️ Partial | May need `all_proxy` |
| `docker` | ✅ Configurable | Docker daemon config |
| `npm` | ✅ Built-in | `https_proxy` env var |
| `pip` | ✅ Built-in | `https_proxy` env var |
| `brew` | ⚠️ Partial | May need `ALL_PROXY` |

### Tools That Don't Work (without workarounds)

| Tool | Reason | Workaround |
|------|--------|------------|
| `ssh` | No proxy env var | Use `ProxyCommand` |
| `scp` | No proxy env var | Use `ssh -D` SOCKS |
| `python requests` | No proxy env var | Use `proxies` dict |
| Custom TCP apps | No proxy support | Not possible without code changes |

---

## 9. File Structure After Redesign

```
CLI-QoS/
├── qos-guard              # Main Bash CLI (updated)
├── qos-proxy              # Go proxy source
│   ├── main.go
│   ├── go.mod
│   └── go.sum
├── qos-proxy-darwin-amd64 # Pre-compiled binary (amd64)
├── qos-proxy-darwin-arm64 # Pre-compiled binary (arm64)
├── Makefile               # Updated with proxy build targets
├── README.md              # Updated documentation
├── prd.md                 # Updated PRD
├── user-stories.md        # Updated user stories
├── architecture-redesign.md  # This document
├── implementation.md      # Technical notes
└── tests/
    └── test-qos-guard.bats  # Updated tests
```

---

## 10. Migration Path

### For Existing Users

1. **No breaking changes** — CLI interface remains the same
2. **Backward compatible** — `qos-guard --help`, `--version`, `--restore` unchanged
3. **Improved functionality** — TCP traffic is now actually limited
4. **Documented limitations** — UDP and non-proxy tools documented

### For New Users

1. Clear documentation of proxy requirement
2. List of supported tools
3. Workarounds for unsupported tools
4. `--dry-run` mode to verify configuration

---

## 11. Decision Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Core approach** | pf + rdr + local proxy | Only viable per-process approach without entitlements |
| **Proxy language** | Go | Single binary, cross-compilable, rate limiting library |
| **TCP limiting** | Proxy-based (token bucket) | Accurate, per-process, works with proxy-aware tools |
| **UDP limiting** | Interface-level (best-effort) | No per-process option without kernel extension |
| **Distribution** | Pre-compiled binaries + source | No build requirement for end users |
| **Privilege** | sudo required | Proxy binds to port, pf rules need root |

---

## 12. Implementation Priority

| Priority | Item | Effort |
|----------|------|--------|
| **P0** | Create `qos-proxy` Go binary | 8 hours |
| **P0** | Update `qos-guard` to use proxy | 4 hours |
| **P1** | Cross-compile binaries | 2 hours |
| **P1** | Update documentation | 3 hours |
| **P2** | Update tests | 3 hours |
| **P2** | Add `--udp-interface` flag | 2 hours |
| **P3** | Homebrew formula for proxy | 1 hour |

**Total Phase 0 effort: ~23 hours**
