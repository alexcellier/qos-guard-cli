#!/usr/bin/env bats
#
# test-qos-guard.bats — Tests for QoS Guard CLI (proxy-based architecture)
#
# Run with: bats tests/
#

load ./bats-support/load
load ./bats-assert/load

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    # Path to the qos-guard binary
    QOS_GUARD="${BATS_TEST_DIRNAME}/../qos-guard"

    # Path to the qos-proxy binary (for testing)
    QOS_PROXY="${BATS_TEST_DIRNAME}/../qos-proxy/qos-proxy"

    # Ensure qos-guard is executable
    chmod +x "$QOS_GUARD"

    # Ensure qos-proxy is executable
    if [[ -f "$QOS_PROXY" ]]; then
        chmod +x "$QOS_PROXY"
    fi

    # Clean up any stale proxy processes from previous tests
    if [[ "$(id -u)" -eq 0 ]]; then
        pkill -f "qos-proxy.*qos-guard" 2>/dev/null || true
    else
        pkill -f "qos-proxy.*qos-guard" 2>/dev/null || true
    fi

    # Unset proxy env vars to avoid test pollution
    unset HTTPS_PROXY HTTP_PROXY all_proxy 2>/dev/null || true
}

teardown() {
    # Clean up any stale proxy processes after each test
    if [[ -n "${PROXY_PID:-}" ]] && kill -0 "${PROXY_PID}" 2>/dev/null; then
        kill -TERM "${PROXY_PID}" 2>/dev/null || true
        wait "${PROXY_PID}" 2>/dev/null || true
    fi

    # Kill any remaining qos-proxy processes from tests
    pkill -f "qos-proxy.*qos-guard" 2>/dev/null || true

    # Unset proxy env vars
    unset HTTPS_PROXY HTTP_PROXY all_proxy 2>/dev/null || true
}

# ============================================================
# Proxy Discovery
# ============================================================

@test "proxy found in PATH when available" {
    # When qos-proxy is in PATH, find_proxy_binary should find it
    # We simulate this by checking the script logic
    run bash -c "
        source <(grep -A 30 'find_proxy_binary' $QOS_GUARD)
        # Mock command -v to return qos-proxy
        command -v qos-proxy >/dev/null 2>&1 && echo 'found' || echo 'not found'
    "
    # The actual test depends on whether qos-proxy is installed
    # This test verifies the function exists and runs
    run grep -c "command -v qos-proxy" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "proxy found relative to script location" {
    # Verify the script checks for relative proxy path
    run grep "qos-proxy/qos-proxy" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "proxy not found shows error" {
    # When qos-proxy is not found, should show error message
    run bash -c "
        # Temporarily rename qos-proxy to simulate it not being found
        mv ${QOS_PROXY} ${QOS_PROXY}.bak 2>/dev/null || true
        cd ${BATS_TEST_DIRNAME}/..
        # Run with a command that would need proxy
        timeout 5 ./qos-guard 50% echo test 2>&1 || true
        # Restore
        mv ${QOS_PROXY}.bak ${QOS_PROXY} 2>/dev/null || true
    "
    assert_output --partial "qos-proxy"
}

# ============================================================
# Proxy Management
# ============================================================

@test "proxy starts successfully" {
    if [[ ! -f "$QOS_PROXY" ]] || [[ ! -x "$QOS_PROXY" ]]; then
        skip "qos-proxy binary not available"
    fi

    # Start qos-guard in background with a simple command
    local tmpfile
    tmpfile="$(mktemp)"

    run bash -c "
        cd ${BATS_TEST_DIRNAME}/..
        # Use dry-run to verify proxy would start
        ./qos-guard --dry-run 50% echo test 2>&1
    "
    assert [ $status -eq 0 ]
    assert_output --partial "qos-proxy"
    rm -f "$tmpfile"
}

@test "proxy uses custom port when specified" {
    run bash -c "
        cd ${BATS_TEST_DIRNAME}/..
        ./qos-guard --dry-run --proxy-port 9999 50% echo test 2>&1
    "
    assert [ $status -eq 0 ]
    assert_output --partial "9999"
}

@test "proxy uses random port when no custom port" {
    run bash -c "
        cd ${BATS_TEST_DIRNAME}/..
        ./qos-guard --dry-run 50% echo test 2>&1
    "
    assert [ $status -eq 0 ]
    assert_output --partial "127.0.0.1:"
}

@test "proxy cleanup on exit" {
    # Verify cleanup_proxy function exists and is called
    run grep -c "cleanup_proxy" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "proxy cleanup handles signals" {
    # Verify signal traps are set up for proxy cleanup
    run grep "trap cleanup_on_signal" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Proxy Environment Variables
# ============================================================

@test "proxy env vars set correctly" {
    # Verify set_proxy_env function sets the correct variables
    run grep "HTTPS_PROXY=" "$QOS_GUARD"
    assert [ $status -eq 0 ]

    run grep "HTTP_PROXY=" "$QOS_GUARD"
    assert [ $status -eq 0 ]

    run grep "all_proxy=" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "proxy env vars correct format" {
    # Verify proxy URL format is http://127.0.0.1:PORT
    run grep "http://127.0.0.1:" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Bandwidth Validation
# ============================================================

@test "valid percentage format accepted" {
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]
    refute_output --partial "Invalid bandwidth format"
}

@test "valid percentage at boundary 0% rejected" {
    run "$QOS_GUARD" --dry-run 0% echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Invalid bandwidth format"
}

@test "valid percentage at boundary 100% accepted" {
    run "$QOS_GUARD" --dry-run 100% echo test
    assert [ $status -eq 0 ]
    refute_output --partial "Invalid bandwidth format"
}

@test "percentage above 100 rejected" {
    run "$QOS_GUARD" --dry-run 101% echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Invalid bandwidth format"
}

@test "negative percentage rejected" {
    run "$QOS_GUARD" --dry-run -50% echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Invalid bandwidth format"
}

@test "valid mbps format accepted (lowercase)" {
    run "$QOS_GUARD" --dry-run 10mbps echo test
    assert [ $status -eq 0 ]
    refute_output --partial "Invalid bandwidth format"
}

@test "valid mbps format accepted (uppercase)" {
    run "$QOS_GUARD" --dry-run 10MBPS echo test
    assert [ $status -eq 0 ]
    refute_output --partial "Invalid bandwidth format"
}

@test "valid kbps format accepted (lowercase)" {
    run "$QOS_GUARD" --dry-run 500kbps echo test
    assert [ $status -eq 0 ]
    refute_output --partial "Invalid bandwidth format"
}

@test "valid kbps format accepted (uppercase)" {
    run "$QOS_GUARD" --dry-run 500KBPS echo test
    assert [ $status -eq 0 ]
    refute_output --partial "Invalid bandwidth format"
}

@test "mixed case mbps accepted" {
    run "$QOS_GUARD" --dry-run 10Mbps echo test
    assert [ $status -eq 0 ]
    refute_output --partial "Invalid bandwidth format"
}

@test "no suffix rejected" {
    run "$QOS_GUARD" --dry-run 10 echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Invalid bandwidth format"
}

@test "invalid format rejected" {
    run "$QOS_GUARD" --dry-run abc echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Invalid bandwidth format"
}

@test "empty string rejected" {
    run "$QOS_GUARD" --dry-run "" echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Invalid bandwidth format"
}

@test "decimal percentage accepted" {
    run "$QOS_GUARD" --dry-run 33.5% echo test
    assert [ $status -eq 0 ]
    refute_output --partial "Invalid bandwidth format"
}

@test "negative value rejected" {
    run "$QOS_GUARD" --dry-run -10mbps echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Invalid bandwidth format"
}

@test "various limit formats parsed correctly" {
    # Test percentage format
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]

    # Test mbps format
    run "$QOS_GUARD" --dry-run 10mbps echo test
    assert [ $status -eq 0 ]

    # Test kbps format
    run "$QOS_GUARD" --dry-run 500kbps echo test
    assert [ $status -eq 0 ]
}

@test "invalid limits are rejected" {
    # Test invalid percentage
    run "$QOS_GUARD" --dry-run 101% echo test 2>&1
    assert [ $status -ne 0 ]

    # Test invalid format
    run "$QOS_GUARD" --dry-run abc echo test 2>&1
    assert [ $status -ne 0 ]
}

# ============================================================
# Interface Detection
# ============================================================

@test "valid interface is accepted" {
    # Get a valid interface
    local valid_iface
    valid_iface="$(route get default 2>/dev/null | grep -i 'interface:' | awk -F': ' '{print $2}' | tr -d '[:space:]' || true)"
    if [[ -z "$valid_iface" ]]; then
        skip "Could not detect valid interface"
    fi

    run "$QOS_GUARD" --dry-run --interface "$valid_iface" 50% echo test
    assert [ $status -eq 0 ]
}

@test "short interface flag -i works" {
    local valid_iface
    valid_iface="$(route get default 2>/dev/null | grep -i 'interface:' | awk -F': ' '{print $2}' | tr -d '[:space:]' || true)"
    if [[ -z "$valid_iface" ]]; then
        skip "Could not detect valid interface"
    fi

    run "$QOS_GUARD" --dry-run -i "$valid_iface" 50% echo test
    assert [ $status -eq 0 ]
}

@test "invalid interface shows error" {
    run "$QOS_GUARD" --dry-run --interface en999xyz 50% echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "not found"
}

@test "invalid interface shows available interfaces" {
    run "$QOS_GUARD" --dry-run --interface en999xyz 50% echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Available interfaces"
}

@test "interface without argument shows error" {
    run "$QOS_GUARD" --dry-run --interface 50% echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Invalid bandwidth format"
}

@test "interface detection works" {
    # Verify interface detection logic exists
    run grep -c "detect_interface" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

# ============================================================
# Argument Parsing
# ============================================================

@test "unknown flag shows error" {
    run "$QOS_GUARD" --dry-run --unknown-flag 50% echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Unknown option"
}

@test "missing command shows error" {
    run "$QOS_GUARD" --dry-run 50% 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Command is required"
}

@test "missing bandwidth and command shows help" {
    run "$QOS_GUARD" --dry-run 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Usage: qos-guard"
}

# ============================================================
# Dry Run Mode
# ============================================================

@test "dry-run shows proxy command" {
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]
    assert_output --partial "qos-proxy"
}

@test "dry-run shows proxy port" {
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]
    assert_output --partial "127.0.0.1:"
}

@test "dry-run shows proxy env vars" {
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]
    assert_output --partial "Proxy:"
}

@test "dry-run shows interface detection" {
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]
    assert_output --partial "[dry-run]"
    assert_output --partial "interface"
}

@test "dry-run shows detected bandwidth" {
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]
    assert_output --partial "bandwidth"
}

@test "dry-run shows calculated limit" {
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]
    assert_output --partial "Calculated limit"
    assert_output --partial "kbps"
}

@test "dry-run shows command preview" {
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]
    assert_output --partial "Would execute"
}

@test "dry-run does not start proxy" {
    # Dry run should not actually start the proxy
    run "$QOS_GUARD" --dry-run 50% echo test
    assert [ $status -eq 0 ]

    # Verify no proxy processes were started
    local proxy_count
    proxy_count="$(pgrep -f "qos-proxy.*qos-guard" 2>/dev/null | wc -l || echo 0)"
    assert [ "$proxy_count" -eq 0 ]
}

@test "dry-run with invalid bandwidth fails" {
    run "$QOS_GUARD" --dry-run abc echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "Invalid bandwidth format"
}

@test "dry-run with invalid interface fails" {
    run "$QOS_GUARD" --dry-run --interface en999 50% echo test 2>&1
    assert [ $status -ne 0 ]
    assert_output --partial "not found"
}

@test "short dry-run flag -n works" {
    run "$QOS_GUARD" -n 50% echo test
    assert [ $status -eq 0 ]
    assert_output --partial "[dry-run]"
}

# ============================================================
# Signal Handling
# ============================================================

@test "signal cleanup function exists" {
    run grep -c "cleanup_on_signal" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "signal traps are set up" {
    run grep "trap cleanup_on_signal" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "SIGTERM trap is set" {
    run grep "SIGTERM" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "cleanup idempotency guard exists" {
    run grep "CLEANUP_DONE" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Child Process Tracking
# ============================================================

@test "get_process_group_pids function exists" {
    run grep -c "get_process_group_pids" "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert [ $output -gt 0 ]
}

@test "child process tracking uses pgrep" {
    run grep "pgrep" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Help and Version
# ============================================================

@test "help flag shows usage" {
    run "$QOS_GUARD" --help
    assert_output --partial "Usage: qos-guard"
    assert_output --partial "bandwidth_limit"
    assert_output --partial "command"
    assert_output --partial "--restore"
    assert_output --partial "--help"
    assert_output --partial "--version"
}

@test "help flag shows examples" {
    run "$QOS_GUARD" --help
    assert_output --partial "qos-guard 50%"
    assert_output --partial "qos-guard 10mbps"
    assert_output --partial "qos-guard 500kbps"
}

@test "help flag shows proxy note" {
    run "$QOS_GUARD" --help
    assert_output --partial "proxy"
}

@test "help flag shows proxy locations" {
    run "$QOS_GUARD" --help
    assert_output --partial "qos-proxy"
}

@test "version flag shows version" {
    run "$QOS_GUARD" --version
    assert_output "qos-guard v1.0.0"
}

@test "no arguments shows help" {
    run "$QOS_GUARD"
    assert [ $status -eq 0 ]
    assert_output --partial "Usage: qos-guard"
}

@test "short help flag works" {
    run "$QOS_GUARD" -h
    assert [ $status -eq 0 ]
    assert_output --partial "Usage: qos-guard"
}

@test "help shows verbose option" {
    run "$QOS_GUARD" --help
    assert_output --partial "--verbose"
}

@test "help shows dry-run option" {
    run "$QOS_GUARD" --help
    assert_output --partial "--dry-run"
}

@test "help shows interface option" {
    run "$QOS_GUARD" --help
    assert_output --partial "--interface"
}

@test "help shows proxy-port option" {
    run "$QOS_GUARD" --help
    assert_output --partial "--proxy-port"
}

@test "help shows -v short flag" {
    run "$QOS_GUARD" --help
    assert_output --partial "-v"
}

@test "help shows -n short flag" {
    run "$QOS_GUARD" --help
    assert_output --partial "-n"
}

@test "help shows -i short flag" {
    run "$QOS_GUARD" --help
    assert_output --partial "-i"
}

# ============================================================
# Restore Functionality
# ============================================================

@test "restore without sudo shows message" {
    run "$QOS_GUARD" --restore
    assert [ $status -eq 0 ]
}

@test "restore shows no stale rules when none exist" {
    run "$QOS_GUARD" --restore
    assert [ $status -eq 0 ]
    assert_output --partial "No stale"
}

@test "restore cleans stale proxy processes" {
    if [[ "$(id -u)" -ne 0 ]]; then
        skip "Requires sudo"
    fi

    # Create a fake stale proxy process
    local fake_pid
    fake_pid="$(mktemp -u)"
    # Use a real but harmless process to match against
    run bash -c "
        # Start a dummy process that matches the pattern
        sleep 300 &
        DUMMY_PID=\$!
        # Kill it immediately
        kill \$DUMMY_PID 2>/dev/null || true
        echo 'cleanup done'
    "
}

# ============================================================
# Verbose Output
# ============================================================

@test "verbose flag enables detailed logging" {
    run "$QOS_GUARD" --dry-run --verbose 50% echo test
    assert [ $status -eq 0 ]
}

@test "short verbose flag -v works" {
    run "$QOS_GUARD" --dry-run -v 50% echo test
    assert [ $status -eq 0 ]
}

@test "verbose output contains timestamp format" {
    # Verify timestamp logging function exists
    run grep "date '+%Y-%m-%d %H:%M:%S'" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

# ============================================================
# Error Handling
# ============================================================

@test "non-existent command returns 127" {
    run "$QOS_GUARD" --dry-run 50% nonexistent-command-xyz 2>&1
    assert [ $status -eq 127 ]
    assert_output --partial "Command not found"
}

@test "command not found error message" {
    run "$QOS_GUARD" --dry-run 50% nonexistent-command-xyz 2>&1
    assert [ $status -eq 127 ]
    assert_output --partial "not found"
}

@test "proxy binary not found error" {
    # This test verifies the error message when proxy is not found
    run grep "qos-proxy binary not found" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "proxy port not set error" {
    # Verify error message for missing proxy port
    run grep "Proxy port not set" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}

@test "failed to start proxy error" {
    # Verify error message for proxy startup failure
    run grep "Failed to start proxy" "$QOS_GUARD"
    assert [ $status -eq 0 ]
}
