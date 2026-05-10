# Architecture Fix Plan: CLI-QoS (QoS Guard CLI)

## Executive Summary

This plan addresses the critical architectural flaw in the current `qos-guard` implementation and provides a detailed roadmap for fixing it while completing the remaining implementation work.

---

## 1. Current State Analysis

### 1.1 What Exists

| Component | Status | Description |
|-----------|--------|-------------|
| [`qos-guard`](qos-guard) | ✅ Complete | Bash CLI with proxy-based bandwidth limiting |
| [`qos-proxy/qos-proxy.go`](qos-proxy/qos-proxy.go) | ✅ Complete | Go binary with HTTP/HTTPS/SOCKS5 proxy + rate limiting |
| [`Makefile`](Makefile) | ✅ Complete | Build configuration with proxy targets |
| [`README.md`](README.md) | ✅ Updated | Documentation updated for proxy architecture |
| [`tests/test-qos-guard.bats`](tests/test-qos-guard.bats) | Exists | Comprehensive BATS test suite (~560 lines) — needs proxy updates |
| [`architecture-redesign.md`](architecture-redesign.md) | Exists | Detailed redesign document identifying the core problem |
| [`implementation.md`](implementation.md) | ✅ Updated | Implementation status with phase tracking |
| [`prd.md`](prd.md) | Exists | Complete PRD with goals, requirements, user stories |
| [`user-stories.md`](user-stories.md) | Exists | Complete user stories with development plan |

### 1.2 Current Implementation Coverage

Based on analysis of [`qos-guard`](qos-guard) and [`tests/test-qos-guard.bats`](tests/test-qos-guard.bats):

| Feature | Status | Notes |
|---------|--------|-------|
| Argument parsing | Done | `--help`, `--version`, `--restore`, `--verbose`, `--dry-run`, `--interface` |
| Bandwidth validation | Done | Percentage, mbps, kbps formats with edge cases |
| Interface detection | Done | `route get default`, `netstat` fallback, manual selection |
| Bandwidth detection | Done | `ifconfig` parsing with 100 Mbps fallback |
| Percentage conversion | Done | Converts % to kbps based on detected bandwidth |
| Absolute conversion | Done | mbps/kbps to kbps |
| Signal handling | Done | SIGINT/SIGTERM traps with cleanup |
| Cleanup on exit | Done | `cleanup_rules()` function |
| Dry-run mode | Done | Full simulation without executing |
| Verbose logging | Done | Timestamped output to stderr |
| `--restore` | Done | Stale rule cleanup |
| Child process tracking | Done | `get_process_group_pids()` function |
| **Per-process bandwidth limiting** | **BROKEN** | Uses invalid `from ${pid}` pf syntax |
| **Proxy infrastructure** | **Missing** | No `qos-proxy` Go binary exists |
| **Go proxy source** | **Missing** | No `qos-proxy/` directory |

---

## 2. Architecture Issues Identified

### CRITICAL: Invalid pf Rule Syntax (The Core Problem)

**Location:** [`qos-guard`](qos-guard:387) line 387-388

```bash
# CURRENT (BROKEN):
pass out on ${INTERFACE} inet from ${target_pid} to any route-to pflow${PIPE_ID}
```

**Problem:** macOS `pf` does **not** support per-PID matching in filter rules. The syntax `from ${target_pid}` is invalid and silently fails. This means:

- **No traffic is actually being limited** — the pipe is created but nothing routes through it
- The tool appears to work (no errors) but has zero effect on bandwidth
- This is a **silent failure** — the most dangerous type

**Evidence in code:**
- [`apply_filter_rule()`](qos-guard:373) function creates invalid rules
- Error suppression via `2>/dev/null` masks the failure
- No validation that rules were actually applied

### Secondary Issues

| Issue | Severity | Location | Description |
|-------|----------|----------|-------------|
| Silent error suppression | High | Multiple | `2>/dev/null` on pfctl commands hides failures |
| No rule verification | Medium | [`apply_filter_rule()`](qos-guard:373) | No check that pf rules were successfully loaded |
| Process tree tracking incomplete | Medium | [`get_process_group_pids()`](qos-guard:302) | Only tracks 2 levels deep (children + grandchildren) |
| Race condition | Medium | [`execute_command()`](qos-guard:456) | Filter rule applied before command starts, but PID may change |
| Pipe cleanup incomplete | Low | [`cleanup_rules()`](qos-guard:408) | Uses `-X` which may not fully remove anchor |

---

## 3. Proposed Architecture Fix

### 3.1 New Architecture Overview

Per [`architecture-redesign.md`](architecture-redesign.md:67), the fix uses a **local proxy approach**:

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

### 3.2 Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Core approach | pf + rdr + local proxy | Only viable per-process approach without entitlements |
| Proxy language | Go | Single binary, cross-compilable, rate limiting library |
| TCP limiting | Proxy-based (token bucket) | Accurate, per-process, works with proxy-aware tools |
| UDP limiting | Interface-level (best-effort) | No per-process option without kernel extension |
| Distribution | Pre-compiled binaries + source | No build requirement for end users |

---

## 4. Architecture Fix Plan

### Phase 0: Core Architecture Fix (P0 - Critical)

#### Task 0.1: Create `qos-proxy` Go Source

**Files to create:**
```
qos-proxy/
├── main.go
├── go.mod
└── README.md
```

**Implementation:**
- HTTP/HTTPS proxy on configurable port
- SOCKS5 proxy on configurable port
- Token bucket rate limiting via `golang.org/x/time/rate`
- Signal handling for cleanup
- Configuration via command-line arguments or environment variables

**Key functions:**
- `NewRateLimitedProxy(cfg ProxyConfig)` — Initialize proxy with rate limiter
- `ServeHTTP()` — HTTP/HTTPS proxy handler
- `ServeSOCKS()` — SOCKS5 proxy handler
- `limitedCopy()` — Rate-limited data forwarding

#### Task 0.2: Cross-compile `qos-proxy` Binaries

**Files to create:**
```
qos-proxy-darwin-amd64
qos-proxy-darwin-arm64
```

**Commands:**
```bash
cd qos-proxy
GOOS=darwin GOARCH=amd64 go build -o ../qos-proxy-darwin-amd64
GOOS=darwin GOARCH=arm64 go build -o ../qos-proxy-darwin-arm64
```

#### Task 0.3: Update `qos-guard` to Use Proxy

**Changes to [`qos-guard`](qos-guard):**

1. **Remove broken pf PID matching:**
   - Remove `apply_filter_rule()` function (lines 373-402)
   - Remove `get_process_group_pids()` function (lines 302-322) — no longer needed for pf rules

2. **Add proxy infrastructure:**
   - Add `detect_proxy_binary()` — Find or extract the proxy binary
   - Add `start_proxy()` — Launch qos-proxy with correct config
   - Add `stop_proxy()` — Kill proxy process on exit
   - Add `set_proxy_env_vars()` — Set `HTTPS_PROXY`, `HTTP_PROXY`, `all_proxy`

3. **Update `execute_command()`:**
   - Set proxy environment variables before command execution
   - Launch proxy before command
   - Pass proxy port to target command
   - Clean up proxy on exit

4. **Update `cleanup_rules()`:**
   - Add proxy process termination
   - Keep pf cleanup for UDP interface-level limiting

5. **Add `--udp-interface` flag:**
   - For UDP traffic that can't use proxy
   - Apply interface-level dummynet limiting

#### Task 0.4: Update `Makefile`

**Add targets:**
```makefile
# Proxy build targets
proxy:
	cd qos-proxy && go build -o ../qos-proxy-darwin-$(ARCH)

proxy-all:
	cd qos-proxy && GOOS=darwin GOARCH=amd64 go build -o ../qos-proxy-darwin-amd64
	cd qos-proxy && GOOS=darwin GOARCH=arm64 go build -o ../qos-proxy-darwin-arm64

# Auto-detect architecture
ARCH := $(shell uname -m)
```

### Phase 1: Foundation Completion (P1)

#### Task 1.1: Update Documentation

**Files to update:**
- [`README.md`](README.md) — Add proxy architecture explanation, supported tools list
- [`prd.md`](prd.md) — Update architecture section
- [`user-stories.md`](user-stories.md) — Update development plan

**New sections needed:**
- How the proxy approach works
- List of proxy-aware tools (curl, wget, git, npm, pip)
- Workarounds for non-proxy tools (proxychains)
- Limitations documentation

#### Task 1.2: Update Tests

**Changes to [`tests/test-qos-guard.bats`](tests/test-qos-guard.bats):**

1. **Update pf-related tests:**
   - Remove tests for broken PID matching
   - Add tests for proxy detection
   - Add tests for proxy environment variables

2. **Add new test categories:**
   - Proxy binary detection
   - Proxy startup/shutdown
   - Proxy environment variable verification
   - UDP interface limiting

### Phase 2: Reliability (P2)

#### Task 2.1: Add Proxy Health Checks

- Verify proxy is running before executing command
- Retry logic for proxy startup failures
- Timeout for proxy initialization

#### Task 2.2: Improve UDP Limiting

- Implement interface-level dummynet for UDP
- Add `--udp-interface` flag
- Document UDP limitations clearly

### Phase 3: Polish & Distribution (P3)

#### Task 3.1: Homebrew Formula

Create `qos-guard` Homebrew formula that includes `qos-proxy`.

#### Task 3.2: Architecture Detection in Install

- Install script detects `uname -m` (amd64 vs arm64)
- Copies correct proxy binary

---

## 5. Implementation Priority Summary

| Priority | Item | Effort | Dependencies | Status |
|----------|------|--------|--------------|--------|
| **P0** | Create `qos-proxy` Go source | 8 hours | None | ✅ Complete |
| **P0** | Cross-compile proxy binaries | 2 hours | P0.1 | ✅ Complete |
| **P0** | Update `qos-guard` to use proxy | 6 hours | P0.1, P0.2 | ✅ Complete |
| **P1** | Update `Makefile` with proxy targets | 2 hours | P0.2 | ✅ Complete |
| **P1** | Update documentation | 4 hours | P0.3 | ✅ Complete |
| **P2** | Update tests | 4 hours | P0.3 | ⏳ Pending |
| **P2** | Add `--udp-interface` flag | 2 hours | P0.3 | ⏳ Pending |
| **P3** | Homebrew formula | 2 hours | P0.3 | ⏳ Pending |

**Completed effort: ~20 hours** | **Remaining effort: ~8 hours**

---

## 6. File Structure After Fix

```
CLI-QoS/
├── qos-guard                    # Main Bash CLI (updated)
├── qos-proxy/                   # Go proxy source (NEW)
│   ├── main.go
│   ├── go.mod
│   └── README.md
├── qos-proxy-darwin-amd64       # Pre-compiled binary (NEW)
├── qos-proxy-darwin-arm64       # Pre-compiled binary (NEW)
├── Makefile                     # Updated with proxy build targets
├── README.md                    # Updated documentation
├── prd.md                       # Updated PRD
├── user-stories.md              # Updated user stories
├── architecture-redesign.md     # This document (reference)
├── implementation.md            # Technical notes
├── plans/
│   └── architecture-fix-plan.md # This file
└── tests/
    └── test-qos-guard.bats      # Updated tests
```

---

## 7. Migration Path

### For Existing Users
- **No breaking changes** — CLI interface remains the same
- **Backward compatible** — `--help`, `--version`, `--restore` unchanged
- **Improved functionality** — TCP traffic is now actually limited
- **Documented limitations** — UDP and non-proxy tools documented

### For New Users
- Clear documentation of proxy requirement
- List of supported tools
- Workarounds for unsupported tools
- `--dry-run` mode to verify configuration

---

## 8. Documented Limitations (Post-Fix)

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| **Proxy-aware only** | Only HTTP/HTTPS/SOCKS traffic is limited | Document which tools support proxy env vars |
| **UDP not per-process** | UDP uses interface-level limiting | Document clearly; offer `--udp-interface` flag |
| **Non-proxy tools** | Tools without proxy support bypass limits | Document workarounds (e.g., `proxychains`) |
| **sudo required** | Proxy binds to port, pf rules need root | Document clearly |
| **macOS 12+ only** | ipfw unavailable on older macOS | Minimum requirement documented |

### Tools That Work (with proxy support)

| Tool | Proxy Support | How |
|------|---------------|-----|
| `curl` | Built-in | `HTTPS_PROXY` env var |
| `wget` | Built-in | `https_proxy` env var |
| `git` | Built-in | `https_proxy` env var |
| `ollama` | Partial | May need `all_proxy` |
| `npm` | Built-in | `https_proxy` env var |
| `pip` | Built-in | `https_proxy` env var |

### Tools That Don't Work (without workarounds)

| Tool | Reason | Workaround |
|------|--------|------------|
| `ssh` | No proxy env var | Use `ProxyCommand` |
| `scp` | No proxy env var | Use `ssh -D` SOCKS |
| Custom TCP apps | No proxy support | Not possible without code changes |

---

## 9. Next Steps

1. **✅ Approve this plan** — Review and approve the architecture fix approach
2. **✅ Switch to Code mode** — Implement Phase 0 tasks
3. **✅ Create `qos-proxy` Go source** — Implement the rate-limited proxy
4. **✅ Update `qos-guard`** — Replace broken pf rules with proxy infrastructure
5. **Update tests** — Add proxy-related tests (Phase 2, pending)
6. **✅ Update documentation** — Reflect new architecture (complete)

### Remaining Work

| Priority | Item | Status |
|----------|------|--------|
| **P2** | Update test suite for proxy architecture | ⏳ Pending |
| **P2** | Add proxy health checks | ⏳ Pending |
| **P2** | Improve UDP limiting with `--udp-interface` flag | ⏳ Pending |
| **P3** | Create Homebrew formula | ⏳ Pending |
