# User Stories & Development Plan: QoS Guard CLI

## Table of Contents

1. [Epic: Bandwidth-Limited Command Execution](#epic-bandwidth-limited-command-execution)
2. [Epic: Bandwidth Detection & Calculation](#epic-bandwidth-detection--calculation)
3. [Epic: Rule Management & Cleanup](#epic-rule-management--cleanup)
4. [Epic: CLI Interface & Help](#epic-cli-interface--help)
5. [Epic: Error Handling & Validation](#epic-error-handling--validation)
6. [Epic: Security & Privilege Management](#epic-security--privilege-management)
7. [Development Plan](#development-plan)

---

## Epic: Bandwidth-Limited Command Execution

### Story 1: Execute Command with Percentage-Based Bandwidth Limit

**Title:** Execute command with percentage-based bandwidth limit

**As a** Developer,
**I want to** run any command with a percentage-based bandwidth limit,
**So that** I can share network bandwidth proportionally with other applications.

**Acceptance Criteria:**
1. Command `qos-guard 50% <command>` applies a 50% bandwidth limit to the executed process
2. The tool automatically detects the active network interface (en0 for WiFi, en1 for Ethernet)
3. The percentage is converted to an absolute kbps value based on detected bandwidth
4. The command executes normally with the limit applied
5. The process completes successfully with the same exit code as the original command

**Edge Cases:**
- Percentage value of 0% should return an error
- Percentage value above 100% should return an error
- Percentage value with invalid format (e.g., `abc%`) should return a validation error
- Network interface with no detected bandwidth should show a warning and default to a conservative estimate

---

### Story 2: Execute Command with Absolute Bandwidth Limit

**Title:** Execute command with absolute bandwidth limit

**As a** DevOps Engineer,
**I want to** run any command with a fixed bandwidth limit (e.g., `10mbps`, `500kbps`),
**So that** I can enforce strict bandwidth caps for compliance or cost reasons.

**Acceptance Criteria:**
1. Command `qos-guard 10mbps <command>` applies a 10 Mbps limit
2. Command `qos-guard 500kbps <command>` applies a 500 Kbps limit
3. Both `mbps` and `kbps` suffixes are supported (case-insensitive)
4. The limit is applied regardless of available bandwidth
5. The command executes normally with the limit applied

**Edge Cases:**
- Missing suffix (e.g., `qos-guard 10 <command>`) should show an error with usage hint
- Invalid numeric value (e.g., `qos-guard abcmbps <command>`) should show a validation error
- Extremely low values (e.g., `1kbps`) should work but warn the user
- Extremely high values (e.g., `10000mbps`) should work but warn if they exceed detected bandwidth

---

### Story 3: Track Child Processes for Bandwidth Limiting

**Title:** Track child processes for bandwidth limit application

**As a** Developer,
**I want** all child processes spawned by my command to inherit the bandwidth limit,
**So that** complex commands (pipelines, scripts, multi-process tools) are fully throttled.

**Acceptance Criteria:**
1. Bandwidth rules apply to the launched process and all its descendants
2. `pf` rules use process group or parent PID matching
3. Child processes created after the initial launch are still captured
4. No child processes escape the bandwidth limit

**Edge Cases:**
- Commands that fork and exec (e.g., `make`, `npm install`) should be fully tracked
- Daemon/spawned processes that detach should still be caught by the rule
- Process groups should be handled correctly on macOS

---

## Epic: Bandwidth Detection & Calculation

### Story 4: Detect Active Network Interface Bandwidth

**Title:** Detect active network interface bandwidth

**As a** Power User,
**I want** the tool to automatically detect my active network interface and its bandwidth,
**So that** percentage-based limits are calculated correctly without manual configuration.

**Acceptance Criteria:**
1. Tool detects the default route interface using `route get default` or `netstat -rn`
2. Interface type is identified (WiFi, Ethernet, Thunderbolt Ethernet, etc.)
3. Bandwidth is extracted from interface configuration using `ifconfig`
4. Detected values are displayed with `--verbose` or `--dry-run` flag
5. Detection fails gracefully with a clear error message

**Edge Cases:**
- Multiple active interfaces (WiFi + Ethernet) — use default route interface
- Virtual interfaces (VPN, Docker, VMware) — exclude from detection
- Interface with no speed information — show warning and use conservative default (100 Mbps)
- Interface down or unavailable — show clear error with instructions

---

### Story 5: Convert Percentage to Absolute Bandwidth

**Title:** Convert percentage to absolute bandwidth value

**As a** Developer,
**I want** percentage values to be accurately converted to kbps,
**So that** the bandwidth limit is applied correctly.

**Acceptance Criteria:**
1. `50%` of 100 Mbps = 50,000 kbps (applied to dummynet pipe)
2. `25%` of 100 Mbps = 25,000 kbps
3. `10%` of 100 Mbps = 10,000 kbps
4. Conversion uses the detected interface bandwidth as the base
5. Conversion is logged when `--verbose` is enabled

**Edge Cases:**
- Detected bandwidth of 0 or unknown — use fallback of 100 Mbps
- Non-standard bandwidths (e.g., 10 Mbps Ethernet) — calculate correctly
- Floating-point percentages (e.g., `33.5%`) — round to nearest integer kbps

---

## Epic: Rule Management & Cleanup

### Story 6: Create pf/dummynet Rules for Bandwidth Limiting

**Title:** Create pf and dummynet rules for bandwidth limiting

**As a** Developer,
**I want** the tool to create appropriate `pf` and `dummynet` rules before executing my command,
**So that** the bandwidth limit is enforced at the network level.

**Acceptance Criteria:**
1. A unique `dummynet` pipe is created with the calculated bandwidth config
2. A `pf` filter rule is added to route the process traffic through the pipe
3. Pipe and rule identifiers are unique (prefixed with `qosguard-` and PID-based)
4. Rules are applied before the command starts executing
5. Rule creation failures are reported with actionable error messages

**Technical Notes:**
- Pipe config: `pipe <id> config bw <value>Kbit`
- Filter rule: `pass out on <iface> inet from <pid> to any route-to <pflow>`
- Rules use `pfctl` with temporary config file

**Edge Cases:**
- Existing pipe with same ID — remove and recreate
- `pfctl` not available — show error with installation instructions
- Invalid interface name — validate before applying rules
- Rule application fails — abort command execution, do not proceed

---

### Story 7: Clean Up Rules on Normal Exit

**Title:** Clean up pf/dummynet rules when command completes

**As a** Any User,
**I want** all created `pf` and `dummynet` rules to be automatically removed when my command finishes,
**So that** I don't need to manually clean up or worry about leftover rules.

**Acceptance Criteria:**
1. Rules are removed immediately after the command exits (success or failure)
2. `pfctl -s pipe` shows no residual `qosguard-*` pipes after completion
3. `pfctl -s filter` shows no residual `qosguard-*` rules after completion
4. Cleanup occurs even if the command exits with a non-zero code
5. No manual intervention is required

**Edge Cases:**
- Command exits via signal (not error) — cleanup still occurs
- Rapid successive commands — each gets its own pipe, cleanup is independent

---

### Story 8: Clean Up Rules on Signal Interrupt

**Title:** Clean up pf/dummynet rules on SIGINT/SIGTERM

**As a** Any User,
**I want** all created `pf` and `dummynet` rules to be removed when I interrupt the command with Ctrl+C,
**So that** no stale rules remain after I cancel an operation.

**Acceptance Criteria:**
1. Pressing Ctrl+C (SIGINT) triggers rule cleanup
2. Sending SIGTERM to the qos-guard process triggers rule cleanup
3. Cleanup completes within 2 seconds of signal receipt
4. No residual `qosguard-*` pipes or rules remain after interrupt
5. User sees a confirmation message: "Rules cleaned up"

**Edge Cases:**
- SIGKILL (kill -9) — cannot be caught; user must use `--restore`
- Multiple rapid interrupts — cleanup is idempotent, no errors
- Command already exited before signal — cleanup is a no-op, no error

---

### Story 9: Recover from Stale Rules

**Title:** Provide --restore flag to clean up stale rules

**As a** Any User,
**I want** a `--restore` command to remove any orphaned `pf` and `dummynet` rules,
**So that** I can recover normal networking if cleanup failed.

**Acceptance Criteria:**
1. `qos-guard --restore` removes all pipes and rules prefixed with `qosguard-`
2. After `--restore`, `pfctl -s pipe` shows no `qosguard-*` entries
3. After `--restore`, `pfctl -s filter` shows no `qosguard-*` entries
4. User sees confirmation: "Cleaned up N pipes and M rules"
5. `--restore` does not affect non-qosguard rules

**Edge Cases:**
- No stale rules found — show "No stale rules found" message
- `--restore` without `sudo` — show error requiring elevated privileges
- Partial cleanup failure — report which items were/were not cleaned

---

## Epic: CLI Interface & Help

### Story 10: Display Help Information

**Title:** Display help information with --help flag

**As a** New User,
**I want** to see clear usage instructions when I run `qos-guard --help`,
**So that** I understand how to use the tool.

**Acceptance Criteria:**
1. `qos-guard --help` displays usage syntax: `qos-guard <bandwidth_limit> <command> [args...]`
2. Help shows argument descriptions (bandwidth_limit, command, args)
3. Help shows available options (--restore, --help, --version, --verbose, --dry-run, --interface)
4. Help includes usage examples (percentage and absolute bandwidth)
5. Help includes a note about `sudo` requirement

**Acceptance Criteria:**
1. `qos-guard --version` displays the current version number
2. Version is consistent with any package manifest (e.g., Makefile, package.json)
3. Output format is clean: `qos-guard v1.0.0`

---

### Story 12: Support Verbose Output

**Title:** Support verbose output for debugging

**As a** Developer,
**I want** to see detailed execution logs with `--verbose`,
**So that** I can understand what the tool is doing and debug issues.

**Acceptance Criteria:**
1. `--verbose` flag enables detailed logging
2. Logs show: detected interface, detected bandwidth, calculated limit, pipe ID, rule commands
3. Logs are sent to stderr (not stdout) to allow clean piping
4. Normal output (without `--verbose`) is silent except for errors
5. Logs include timestamps for timing analysis

**Example Verbose Output:**
```
[2026-05-10 10:30:00] Detected interface: en0 (WiFi)
[2026-05-10 10:30:00] Detected bandwidth: 100 Mbps
[2026-05-10 10:30:00] Calculated limit (50%): 50000 kbps
[2026-05-10 10:30:00] Created pipe 1001: bw 50000Kbit
[2026-05-10 10:30:00] Applied pf rule: pass out on en0 inet from 12345 to any route-to pflow1001
[2026-05-10 10:30:00] Executing: ollama pull biglm
[2026-05-10 10:35:00] Command completed (exit code 0)
[2026-05-10 10:35:00] Cleaned up pipe 1001 and associated rules
```

---

### Story 13: Support Dry-Run Mode

**Title:** Support dry-run mode for previewing actions

**As a** Developer,
**I want** to preview what `qos-guard` would do without actually applying rules,
**So that** I can verify my configuration before committing to it.

**Acceptance Criteria:**
1. `--dry-run` flag shows what would happen without executing the command
2. Output includes: detected interface, calculated limit, commands that would run
3. No rules are created, no pipes are added
4. Exit code is 0 if validation passes, non-zero if validation fails
5. `--dry-run` implies `--verbose` behavior

---

### Story 14: Support Manual Interface Selection

**Title:** Allow manual network interface selection

**As a** Power User with multiple interfaces,
**I want** to specify which network interface to use with `--interface`,
**So that** I can target a specific connection when multiple are active.

**Acceptance Criteria:**
1. `--interface en0` targets the specified interface
2. `--interface en1` targets an alternative interface
3. Invalid interface name shows an error: "Interface 'enX' not found"
4. Interface must be up/active to be selected
5. If `--interface` is not specified, auto-detection is used

**Edge Cases:**
- Interface does not exist — show error with available interfaces list
- Interface is down — show error suggesting an active interface
- Interface has no speed info — warn and use conservative default

---

## Epic: Error Handling & Validation

### Story 15: Validate Bandwidth Input

**Title:** Validate bandwidth limit input format

**As a** User,
**I want** invalid bandwidth values to be caught and reported early,
**So that** I can correct my input before any system changes occur.

**Acceptance Criteria:**
1. Valid formats accepted: `50%`, `10mbps`, `500kbps`, `10MBPS`, `500KBPS`
2. Invalid format `abc` shows: "Invalid bandwidth format: 'abc'. Use examples: 50%, 10mbps, 500kbps"
3. Negative values show: "Bandwidth value cannot be negative: '-10%'"
4. Empty input shows: "Bandwidth value is required. Use examples: 50%, 10mbps, 500kbps"
5. Validation happens before any system changes (pf rules, pipes)

**Edge Cases:**
- Leading/trailing whitespace — trim and validate
- Mixed case suffixes (`10MBPS`, `10Mbps`) — accept all variations
- Scientific notation (`1e3kbps`) — reject with clear error
- Very large numbers (`999999999mbps`) — warn but accept

---

### Story 16: Handle Missing Command

**Title:** Handle missing or invalid command argument

**As a** User,
**I want** a clear error when I forget to provide a command,
**So that** I know exactly what I missed.

**Acceptance Criteria:**
1. `qos-guard 50%` (no command) shows: "Error: Command is required. Usage: qos-guard <bandwidth_limit> <command> [args...]"
2. `qos-guard` (no arguments) shows full help output
3. Error exit code is 1
4. No system changes are made when command is missing

---

### Story 17: Handle Command Execution Failures

**Title:** Handle command execution failures gracefully

**As a** User,
**I want** rules to be cleaned up even if my command fails,
**So that** I never have leftover network rules.

**Acceptance Criteria:**
1. If the command fails (non-zero exit), rules are still cleaned up
2. The original exit code is preserved and returned to the shell
3. User sees the command's error output (not suppressed)
4. No additional error messages are shown for the command failure itself
5. Cleanup success is logged with `--verbose`

**Edge Cases:**
- Command not found — show "Command not found: <name>" and exit 127 (like bash)
- Command requires elevated privileges — show warning but proceed (user may have sudo)
- Command is a built-in shell function — warn that it may not work as expected

---

## Epic: Security & Privilege Management

### Story 18: Require and Handle sudo Privileges

**Title:** Require sudo for pf rule management

**As a** User,
**I want** clear guidance when I need elevated privileges,
**So that** I can run the tool correctly.

**Acceptance Criteria:**
1. Rule creation requires `sudo` — tool checks for root privileges
2. Without `sudo`, show: "Error: sudo is required to manage network rules. Use: sudo qos-guard 50% <command>"
3. `--restore` without `sudo` shows the same message
4. `--help` and `--version` work without `sudo`
5. Help text includes `sudo` requirement notice

**Edge Cases:**
- `SUDO_USER` is set but process is not root — still require sudo for the actual operation
- Root user running directly — proceed without sudo wrapper
- Privilege check fails unexpectedly — show generic error with troubleshooting steps

---

### Story 19: Scope Rules to Specific Process Only

**Title:** Ensure pf rules only affect the target process

**As a** Security-conscious User,
**I want** bandwidth rules to affect only my command's process tree,
**So that** other applications are not impacted.

**Acceptance Criteria:**
1. Rules use PID-based matching, not global/interface-wide rules
2. No permanent pf configuration changes are made (rules are session-only)
3. Rules do not affect traffic from other processes
4. Rule scope is verified: `pfctl -s filter` shows only the expected rules
5. Cleanup removes all rules created by this invocation

**Edge Cases:**
- Process exits quickly before rule is applied — rule is cleaned up on startup
- Multiple qos-guard instances running simultaneously — each has unique pipe/rule IDs
- pf is disabled or unavailable — show clear error with instructions to enable

---

## Epic: Installation & Distribution

### Story 20: Install via Multiple Methods

**Title:** Support multiple installation methods

**As a** User,
**I want** to install qos-guard using my preferred method,
**So that** I can get started quickly.

**Acceptance Criteria:**
1. Installation via copy: `cp qos-guard /usr/local/bin/qos-guard` works
2. Installation via Homebrew is documented (or available in a tap)
3. `make install` target is available for source installation
4. Installation instructions are in the README
5. Post-installation verification command is provided (`qos-guard --version`)

---

## Development Plan

### Phase 1: Foundation (Sprint 1)

**Goal:** Core CLI with basic bandwidth limiting

| # | Task | Story | Estimated Effort | Dependencies |
|---|------|-------|-----------------|--------------|
| 1.1 | Create project structure and Makefile | — | 1 hour | — |
| 1.2 | Implement argument parsing (`--help`, `--version`, `--restore`) | US-11, US-10 | 2 hours | 1.1 |
| 1.3 | Implement bandwidth input validation | US-15 | 2 hours | 1.2 |
| 1.4 | Implement network interface detection | US-4 | 3 hours | — |
| 1.5 | Implement percentage-to-kbps conversion | US-5 | 1 hour | 1.4 |
| 1.6 | Implement basic pf/dummynet rule creation | US-6 | 4 hours | 1.4, 1.5 |
| 1.7 | Implement command execution with rule application | US-1, US-2 | 3 hours | 1.6 |
| 1.8 | Implement basic cleanup on exit | US-7 | 2 hours | 1.6 |
| 1.9 | Manual testing of core functionality | AC-1, AC-2 | 3 hours | 1.7, 1.8 |

**Phase 1 Deliverable:** A working `qos-guard` that can run commands with bandwidth limits and clean up after itself.

---

### Phase 2: Reliability (Sprint 2)

**Goal:** Robust signal handling and stale rule recovery

| # | Task | Story | Estimated Effort | Dependencies |
|---|------|-------|-----------------|--------------|
| 2.1 | Implement SIGINT/SIGTERM traps | US-8 | 2 hours | 1.8 |
| 2.2 | Implement `--restore` functionality | US-9 | 2 hours | 1.6 |
| 2.3 | Implement verbose logging | US-12 | 2 hours | 1.2 |
| 2.4 | Implement dry-run mode | US-13 | 2 hours | 1.4, 1.5 |
| 2.5 | Implement manual interface selection | US-14 | 2 hours | 1.4 |
| 2.6 | Handle child process tracking | US-3 | 4 hours | 1.6 |
| 2.7 | Comprehensive testing of signal handling | AC-3 | 3 hours | 2.1, 2.2 |
| 2.8 | Test stale rule recovery scenarios | AC-4 | 2 hours | 2.2 |

**Phase 2 Deliverable:** A reliable tool with proper signal handling, verbose output, dry-run mode, and stale rule recovery.

---

### Phase 3: Polish & Distribution (Sprint 3)

**Goal:** Error handling, documentation, and distribution

| # | Task | Story | Estimated Effort | Dependencies |
|---|------|-------|-----------------|--------------|
| 3.1 | Implement sudo requirement check | US-18 | 1 hour | 1.2 |
| 3.2 | Improve error messages and validation | US-15, US-16, US-17 | 3 hours | 1.2, 1.5 |
| 3.3 | Write README with installation and usage docs | US-20 | 3 hours | — |
| 3.4 | Create Homebrew formula | US-20 | 2 hours | 3.3 |
| 3.5 | Add `make install` target | US-20 | 1 hour | 3.3 |
| 3.6 | Performance testing (overhead measurement) | NFR-3 | 2 hours | 2.7 |
| 3.7 | Cross-version macOS compatibility testing | NFR-5 | 3 hours | — |
| 3.8 | Final integration testing | AC-1 to AC-6 | 4 hours | 2.7, 3.6 |

**Phase 3 Deliverable:** A polished, documented, and distributable release of qos-guard.

---

### Total Estimated Effort

| Phase | Story Points | Calendar Time |
|-------|-------------|---------------|
| Phase 1: Foundation | ~21 hours | 3 days |
| Phase 2: Reliability | ~22 hours | 3 days |
| Phase 3: Polish & Distribution | ~19 hours | 2-3 days |
| **Total** | **~62 hours** | **~2 weeks** |

---

### Risk Register

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| `pf`/`dummynet` behavior varies across macOS versions | Medium | High | Test on macOS 12, 13, 14; add version detection |
| `sudo` friction reduces adoption | Medium | Medium | Clear documentation; suggest shell alias |
| Child process tracking is incomplete | Medium | High | Use process group IDs; test with common tools |
| Rule conflicts with existing firewall | Low | High | Use unique prefixes; warn user; provide `--restore` |
| Interface detection fails on exotic setups | Low | Medium | Allow manual `--interface` override |

---

### Success Criteria for Release

| Criterion | Target |
|-----------|--------|
| All acceptance criteria (AC-1 to AC-6) verified | 100% pass rate |
| Bandwidth limit accuracy within ±10% | Confirmed via testing |
| Rule cleanup on all exit paths | 100% success rate |
| No third-party dependencies | Confirmed |
| macOS 12+ compatibility | Tested on all supported versions |
| Documentation complete | README, help text, examples |
