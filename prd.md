# Product Requirements Document: QoS Guard CLI

## 1. Overview

### 1.1 Product Name
**QoS Guard CLI** — A macOS command-line tool for per-process bandwidth limiting.

### 1.2 Problem Statement
Users running bandwidth-intensive operations (e.g., downloading large models, updating systems, streaming) often need to limit network usage to avoid impacting other applications or staying within data caps. macOS lacks a simple, built-in per-process bandwidth limiter accessible from the command line.

### 1.3 Solution
A lightweight CLI utility that uses a local proxy-based approach with a Go binary (`qos-proxy`) to apply real-time bandwidth limits to individual commands. The tool starts a local rate-limiting proxy, sets `HTTP_PROXY`/`HTTPS_PROXY`/`all_proxy` environment variables for the target command, and cleans up on exit.

---

## 2. Goals

| Goal | Description |
|------|-------------|
| **G1** | Enable users to limit bandwidth for any command with a simple, intuitive CLI interface |
| **G2** | Use only macOS native mechanisms where possible — Go runtime for proxy only |
| **G3** | Provide automatic cleanup of network rules when the commanded process exits |
| **G4** | Support both percentage-based and absolute bandwidth limits |
| **G5** | Ensure safe, reversible operation with minimal privilege requirements |

---

## 3. Target Users

| User Type | Description |
|-----------|-------------|
| **Developers** | Managing large downloads (e.g., `ollama pull`, `git clone`, `docker pull`) without saturating bandwidth |
| **DevOps Engineers** | Running CI/CD tasks that must coexist with other network-dependent services |
| **Power Users** | Controlling network usage on shared or metered connections |

---

## 4. Functional Requirements

### 4.1 Core Features

| ID | Feature | Description |
|----|---------|-------------|
| **FR-1** | Bandwidth-Limited Command Execution | Run any command with an applied bandwidth limit |
| **FR-2** | Percentage-Based Limits | Accept percentage of available bandwidth (e.g., `50%`) |
| **FR-3** | Absolute Bandwidth Limits | Accept fixed rates in kbps or mbps (e.g., `10mbps`, `500kbps`) |
| **FR-4** | Automatic Rule Cleanup | Remove `pf`/`dummynet` rules when the command completes or is interrupted |
| **FR-5** | Stale Rule Recovery | Provide a `--restore` flag to clean up any orphaned rules |
| **FR-6** | Current Bandwidth Detection | Detect available interface bandwidth automatically |

### 4.2 CLI Interface

```
qos-guard <bandwidth_limit> <command> [args...]
```

#### Usage Examples

| Command | Description |
|---------|-------------|
| `qos-guard 50% ollama pull biglm` | Limit to 50% of available bandwidth |
| `qos-guard 10mbps curl https://example.com` | Limit to 10 Mbps |
| `qos-guard 500kbps wget large-file.tar` | Limit to 500 Kbps |
| `qos-guard --restore` | Clean up stale rules |

#### Help Output

```
Usage: qos-guard <bandwidth_limit> <command> [args...]

Arguments:
  bandwidth_limit    Bandwidth limit (e.g., 50%, 10mbps, 500kbps)
  command            Command to execute
  args               Arguments for the command

Options:
  --restore          Clean up any stale pf/dummynet rules
  --help             Show this help message
  --version          Show version
```

---

## 5. Non-Functional Requirements

| ID | Requirement | Description |
|----|-------------|-------------|
| **NFR-1** | Minimal Dependencies | Only Go runtime for proxy; no other third-party dependencies |
| **NFR-2** | Privilege Model | Requires `sudo` for proxy binding and pf rules; clearly documented |
| **NFR-3** | Performance | Minimal overhead (<5%) beyond the applied bandwidth limit |
| **NFR-4** | Reliability | Proxy is cleaned up on normal exit, SIGINT, and SIGTERM |
| **NFR-5** | Compatibility | Supports macOS 12+ (Monterey and later) |
| **NFR-6** | Security | Proxy is scoped to the specific command; no global network changes |

---

## 6. Technical Architecture

### 6.1 System Design

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
│  │ 3. Start      │──→ Launch qos-proxy with rate limit   │
│  │    proxy      │    (token bucket, random port)        │
│  └──────────────┘                                         │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────┐                                         │
│  │ 4. Set        │──→ HTTPS_PROXY, HTTP_PROXY,           │
│  │    proxy env  │    all_proxy = http://127.0.0.1:PORT  │
│  └──────────────┘                                         │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────┐                                         │
│  │ 5. Execute    │──→ Run command with proxy env vars    │
│  │    command    │    (curl, wget, git, etc.)            │
│  └──────────────┘                                         │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────┐                                         │
│  │ 6. Cleanup    │──→ Kill proxy, reset env vars on exit │
│  │    on exit    │    (trap SIGINT/SIGTERM)              │
│  └──────────────┘                                         │
└─────────────────────────────────────────────────────────┘
```

### 6.2 Network Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Network Flow                             │
│                                                             │
│  ollama process ──→ HTTPS_PROXY ──→ qos-proxy ──→ Internet │
│                    (env var)      (rate limit)   (en0)      │
│                                                             │
│  Traffic is limited by:                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  | Token Bucket Rate Limiter                           │   │
│  | bw = 50% of detected interface bandwidth            │   │
│  | Algorithm: Token bucket with burst capacity         │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Tech Stack** | `pf` + `rdr` + local proxy | Only viable per-process approach without entitlements |
| **Proxy Language** | Go | Single binary, cross-compilable, rate limiting library |
| **TCP Limiting** | Proxy-based (token bucket) | Accurate, per-process, works with proxy-aware tools |
| **UDP Limiting** | Interface-level (best-effort) | No per-process option without kernel extension |
| **Implementation Language** | Bash + Go proxy | Bash for CLI, Go for rate limiting |
| **Privilege Model** | `sudo` required | Proxy binding and pf rules need root |
| **Cleanup Strategy** | Signal traps | Auto-cleanup on exit, SIGINT, SIGTERM |

---

## 7. User Stories

| ID | As a... | I want to... | So that... |
|----|----------|-------------|------------|
| **US-1** | Developer | Run a command with a bandwidth limit | I can download large files without disrupting other work |
| **US-2** | Power User | Limit bandwidth by percentage | I can proportionally share bandwidth across applications |
| **US-3** | DevOps Engineer | Use absolute bandwidth values | I can enforce strict limits for compliance or cost reasons |
| **US-4** | Any User | Have rules auto-cleaned | I don't need to manually manage network rules |
| **US-5** | Any User | Recover from stale rules | I can restore normal networking without rebooting |
| **US-6** | Developer | Get clear error messages | I can quickly diagnose and fix issues |

---

## 8. Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|-------------|
| **AC-1** | Command executes with applied bandwidth limit | Measured throughput matches configured limit |
| **AC-2** | Rules are cleaned up on normal exit | `pfctl -s pipe` shows no residual rules |
| **AC-3** | Rules are cleaned up on SIGINT (Ctrl+C) | `pfctl -s pipe` shows no residual rules after interrupt |
| **AC-4** | `--restore` removes stale rules | All orphaned pipes/queues are removed |
| **AC-5** | Percentage limits scale with available bandwidth | 50% limit adjusts when total bandwidth changes |
| **AC-6** | Help and version flags work correctly | Output matches expected format |

---

## 9. Out of Scope

| Item | Reason |
|------|--------|
| iOS support | Requires jailbreak or different framework (NetworkExtension) |
| GUI application | CLI is the primary use case; GUI can be built later |
| Cross-platform support | `pf`/`dummynet` are macOS-specific |
| Real-time dashboard | Monitoring can be done with separate tools (`nettop`, `ifstat`) |
| Persistent rules | Rules are session-based by design |

---

## 10. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `pf` rules conflict with existing firewall | Medium | Use unique pipe names; warn user before applying |
| `sudo` requirement causes friction | Low | Clear documentation; suggest alias for convenience |
| Interface detection fails on multi-interface Macs | Medium | Allow manual interface selection (`--interface en0`) |
| Rules not cleaned up on crash | Low | `--restore` flag; periodic cleanup script option |

---

## 11. Success Metrics

| Metric | Target |
|--------|--------|
| Bandwidth limit accuracy | ±10% of configured limit |
| Rule cleanup success rate | 100% on normal exit/interrupt |
| Overhead (CPU/memory) | <5% additional resource usage |
| User adoption | 100+ users in first 3 months |

---

## 12. Future Enhancements

| ID | Enhancement | Priority |
|----|-------------|----------|
| **FE-1** | Configuration file for persistent presets | Medium |
| **FE-2** | Per-IP/port targeting | Low |
| **FE-3** | Integration with `tmux`/`screen` | Low |
| **FE-4** | GUI companion app | Low |
| **FE-5** | Linux support via `tc` (traffic control) | Medium |

---

## 13. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-05-10 | Documentation Team | Initial draft |
