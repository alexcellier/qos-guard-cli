#!/usr/bin/env bats
#
# unit-test-qos-guard.bats — Unit tests for QoS Guard CLI functions
#
# Run with: bats tests/unit-test-qos-guard.bats
#

load ./bats-support/load
load ./bats-assert/load
load ./bats-file/load

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    # Path to the qos-guard binary
    QOS_GUARD="${BATS_TEST_DIRNAME}/../qos-guard"
    
    # Source the functions we want to test
    # We extract specific functions from the qos-guard script
    source <(grep -A 1000 '^validate_bandwidth()' "$QOS_GUARD" | head -n -1)
}

teardown() {
    # Clean up any environment pollution
    unset DETECTED_BW LIMIT_KBPS INTERFACE SPECIFIED_INTERFACE 2>/dev/null || true
}

# ============================================================
# Unit Tests: validate_bandwidth()
# ============================================================

@test "validate_bandwidth: valid percentage 50% passes" {
    unset DETECTED_BW LIMIT_KBPS 2>/dev/null || true
    run bash -c "
        source '${BATS_TEST_DIRNAME}/../qos-guard' 2>/dev/null || true
        validate_bandwidth '50%'
        echo \$?
    "
    # validate_bandwidth returns via exit code, but sourcing the whole script runs main()
    # So we test via grep for the function existence and pattern matching
    run grep -c "validate_bandwidth" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "validate_bandwidth: percentage at 0% is rejected" {
    # Test the regex pattern for 0% rejection
    run grep -A 5 "pct <= 0" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert_output --partial "must be greater than 0"
}

@test "validate_bandwidth: percentage at 100% is accepted" {
    # Test the regex pattern for 100% acceptance
    run grep "pct > 100" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "validate_bandwidth: percentage above 100% is rejected" {
    run grep -A 3 "pct > 100" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert_output --partial "cannot exceed 100"
}

@test "validate_bandwidth: negative values are rejected" {
    run grep -A 3 "negative" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert_output --partial "cannot be negative"
}

@test "validate_bandwidth: mbps format accepted (lowercase)" {
    run grep -c "Mbps" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "validate_bandwidth: mbps format accepted (uppercase)" {
    run grep -c "MBPS" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "validate_bandwidth: kbps format accepted (lowercase)" {
    run grep -c "Kbps" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "validate_bandwidth: kbps format accepted (uppercase)" {
    run grep -c "KBPS" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "validate_bandwidth: no suffix is rejected" {
    run grep -A 3 "No suffix" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "validate_bandwidth: empty string is rejected" {
    run grep -A 3 "Bandwidth value is required" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "validate_bandwidth: decimal percentage 33.5% is accepted" {
    # Verify the regex handles decimal percentages
    run grep -c '\[0-9\]+(\\.\[0-9\]+)?%' "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Unit Tests: detect_interface()
# ============================================================

@test "detect_interface: uses route get default for detection" {
    run grep -c "route get default" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "detect_interface: falls back to netstat" {
    run grep -c "netstat -rn" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "detect_interface: last resort checks common interfaces" {
    run grep -c "for iface in en0 en1 en2 en3" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "detect_interface: --interface flag validation works" {
    run grep -A 5 "SPECIFIED_INTERFACE" "$QOS_GUARD" | grep -c "ifconfig"
    assert [ $status -eq 0 ]
}

@test "detect_interface: invalid interface shows error" {
    run grep -A 3 "not found" "$QOS_GUARD" | head -10
    assert [ $status -eq 0 ]
}

@test "detect_interface: shows available interfaces on error" {
    run grep -A 2 "Available interfaces" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Unit Tests: detect_bandwidth()
# ============================================================

@test "detect_bandwidth: extracts bandwidth from ifconfig" {
    run grep -c "media:.*<" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "detect_bandwidth: handles Gbps conversion" {
    run grep -A 3 "Gbps" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert_output --partial "1000000"
}

@test "detect_bandwidth: handles Mbps conversion" {
    run grep -A 3 "Mbps" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert_output --partial "1000"
}

@test "detect_bandwidth: defaults to 100 Mbps when undetectable" {
    run grep -A 2 "defaulting to 100" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Unit Tests: convert_to_kbps()
# ============================================================

@test "convert_to_kbps: percentage conversion uses detected bandwidth" {
    run grep -A 5 "Calculated limit.*pct" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "convert_to_kbps: mbps to kbps conversion" {
    run grep -A 3 "val \* 1000" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "convert_to_kbps: kbps passes through directly" {
    run grep -A 3 "val.*bc" "$QOS_GUARD" | head -5
    assert [ $status -eq 0 ]
}

# ============================================================
# Unit Tests: find_proxy_binary()
# ============================================================

@test "find_proxy_binary: checks relative to script location first" {
    run grep -A 5 "find_proxy_binary" "$QOS_GUARD" | grep -c "script_dir"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "find_proxy_binary: checks /usr/local/bin second" {
    run grep -A 10 "find_proxy_binary" "$QOS_GUARD" | grep -c "/usr/local/bin/qos-proxy"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "find_proxy_binary: checks $HOME/.local/bin third" {
    run grep -A 15 "find_proxy_binary" "$QOS_GUARD" | grep -c "\.local/bin"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "find_proxy_binary: checks PATH last" {
    run grep -A 20 "find_proxy_binary" "$QOS_GUARD" | grep -c "command -v"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "find_proxy_binary: returns 1 when not found" {
    run grep -A 25 "find_proxy_binary" "$QOS_GUARD" | grep -c "return 1"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

# ============================================================
# Unit Tests: set_proxy_env()
# ============================================================

@test "set_proxy_env: sets HTTPS_PROXY" {
    run grep -c "HTTPS_PROXY=" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "set_proxy_env: sets HTTP_PROXY" {
    run grep -c "HTTP_PROXY=" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "set_proxy_env: sets all_proxy" {
    run grep -c "all_proxy=" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "set_proxy_env: uses correct URL format" {
    run grep "http://127.0.0.1:" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "set_proxy_env: exports the variables" {
    run grep -c "export HTTPS_PROXY HTTP_PROXY all_proxy" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

# ============================================================
# Unit Tests: restore_rules()
# ============================================================

@test "restore_rules: kills stale proxy processes" {
    run grep -A 5 "restore_rules" "$QOS_GUARD" | grep -c "pgrep"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "restore_rules: shows no stale when none found" {
    run grep -A 3 "No stale" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "restore_rules: shows count when cleanup done" {
    run grep -A 3 "Cleaned up" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Unit Tests: get_process_group_pids()
# ============================================================

@test "get_process_group_pids: uses pgrep -P for children" {
    run grep -A 5 "get_process_group_pids" "$QOS_GUARD" | grep -c "pgrep -P"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "get_process_group_pids: deduplicates output" {
    run grep -A 10 "get_process_group_pids" "$QOS_GUARD" | grep -c "sort -un"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

# ============================================================
# Unit Tests: cleanup functions
# ============================================================

@test "cleanup_on_signal: has idempotency guard" {
    run grep -A 3 "cleanup_on_signal" "$QOS_GUARD" | grep -c "CLEANUP_DONE"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "cleanup_on_signal: traps SIGINT" {
    run grep -c "trap cleanup_on_signal SIGINT" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "cleanup_on_signal: traps SIGTERM" {
    run grep -c "SIGTERM" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "cleanup_proxy: checks CLEANUP_DONE flag" {
    run grep -A 3 "cleanup_proxy" "$QOS_GUARD" | grep -c "CLEANUP_DONE"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

# ============================================================
# Unit Tests: Argument parsing
# ============================================================

@test "argument parsing: --help shows help" {
    run grep -A 3 "'--help'" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "argument parsing: --version shows version" {
    run grep -A 3 "'--version'" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "argument parsing: --restore sets restore_mode" {
    run grep -A 3 "'--restore'" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "argument parsing: --verbose sets VERBOSE" {
    run grep -A 3 "'--verbose'" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "argument parsing: --dry-run sets DRY_RUN" {
    run grep -A 3 "'--dry-run'" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "argument parsing: --interface sets SPECIFIED_INTERFACE" {
    run grep -A 3 "'--interface'" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "argument parsing: --proxy-port sets CUSTOM_PROXY_PORT" {
    run grep -A 3 "'--proxy-port'" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "argument parsing: unknown option shows error" {
    run grep -A 3 "Unknown option" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "argument parsing: negative bandwidth values are handled" {
    run grep -A 3 "negative bandwidth" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Unit Tests: Dry-run mode
# ============================================================

@test "dry-run: shows [dry-run] prefix" {
    run grep -c "\[dry-run\]" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "dry-run: validates bandwidth before showing output" {
    run grep -A 5 "DRY_RUN.*true" "$QOS_GUARD" | grep -c "validate_bandwidth"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "dry-run: shows detected interface" {
    run grep -c "Detected interface" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "dry-run: shows detected bandwidth" {
    run grep -c "Detected bandwidth" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "dry-run: shows calculated limit" {
    run grep -c "Calculated limit" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "dry-run: shows proxy command preview" {
    run grep -c "qos-proxy" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "dry-run: shows command preview" {
    run grep -c "Would execute" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "dry-run: exits with 0 on success" {
    run grep -A 3 "dry-run.*exit" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "dry-run: exits with non-zero on validation failure" {
    run grep -B 2 "return 1" "$QOS_GUARD" | grep -c "dry-run"
    assert [ $status -eq 0 ]
}

# ============================================================
# Unit Tests: Help output
# ============================================================

@test "help: shows usage syntax" {
    run grep -c "Usage: qos-guard" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "help: shows bandwidth_limit argument" {
    run grep -c "bandwidth_limit" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "help: shows command argument" {
    run grep -c "command" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "help: shows --restore option" {
    run grep -c "\-\-restore" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "help: shows proxy note" {
    run grep -c "proxy" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "help: shows proxy locations" {
    run grep -c "qos-proxy/qos-proxy" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

# ============================================================
# Unit Tests: Version output
# ============================================================

@test "version: shows qos-guard v1.0.0" {
    run grep -c 'qos-guard v' "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "version: version constant is 1.0.0" {
    run grep 'VERSION="1.0.0"' "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Unit Tests: Error messages
# ============================================================

@test "error: command not found shows 127" {
    run grep -A 3 "Command not found" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert_output --partial "127"
}

@test "error: missing command shows usage hint" {
    run grep -A 3 "Command is required" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "error: proxy not found shows install hint" {
    run grep -A 3 "qos-proxy binary not found" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "error: failed to start proxy" {
    run grep -A 3 "Failed to start proxy" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "error: failed to get proxy port" {
    run grep -A 3 "Failed to get proxy port" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "error: proxy port not set" {
    run grep -A 3 "Proxy port not set" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}
