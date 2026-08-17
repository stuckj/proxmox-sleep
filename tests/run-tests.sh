#!/bin/bash
#
# Offline test harness for Proxmox Sleep Manager.
#
# Runs both scripts end-to-end through their real CLI subcommands with
# qm/pct/pvesh/nvidia-smi/systemctl replaced by mocks (tests/mocks/). No
# Proxmox host, no root, and no network required.
#
# Usage:
#   tests/run-tests.sh              # run everything
#   tests/run-tests.sh gaming       # run tests whose name matches a substring
#   VERBOSE=1 tests/run-tests.sh    # dump script output for every test
#
# Each test runs in its own subshell with a private sandbox directory, so
# MOCK_* variables and config never leak between tests.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCKS="$REPO_ROOT/tests/mocks"
MONITOR="$REPO_ROOT/proxmox-idle-monitor.sh"
MANAGER="$REPO_ROOT/proxmox-sleep-manager.sh"
BASE_PATH="$PATH"
FILTER="${1:-}"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILED_TESTS=()

# ── Assertions ────────────────────────────────────────────────────────────────
# Each records a line in $ASSERT_FAILURES; a test fails iff that file is
# non-empty. Assertions never abort, so one test can report several problems.

fail_assert() { printf '%s\n' "$1" >> "$ASSERT_FAILURES"; }

assert_contains() { # desc haystack needle
    [[ "$2" == *"$3"* ]] || fail_assert "$1: expected to contain '$3'"
}

assert_not_contains() { # desc haystack needle
    [[ "$2" != *"$3"* ]] || fail_assert "$1: expected NOT to contain '$3'"
}

assert_eq() { # desc actual expected
    [[ "$2" == "$3" ]] || fail_assert "$1: expected '$3', got '$2'"
}

assert_rc() { # desc actual expected
    [[ "$2" == "$3" ]] || fail_assert "$1: expected exit $3, got $2"
}

# ── Helpers available to tests ────────────────────────────────────────────────

write_config() { cat > "$CONFIG_FILE"; }

state_file() { printf '%s' "$PROXMOX_SLEEP_STATE_DIR/sleep-manager.state"; }

# Contents of the sleep-manager state file (empty string when absent).
read_state() {
    local f; f="$(state_file)"
    [[ -f "$f" ]] && cat "$f" || true
}

calls() { cat "$MOCK_CALL_LOG" 2>/dev/null || true; }

# Make the host-side nvidia-smi mock visible to the script under test.
with_nvidia() { export PATH="$MOCKS/optional:$PATH"; }

monitor() { bash "$MONITOR" "$@" 2>&1; }
manager() { bash "$MANAGER" "$@" 2>&1; }

# ── Runner ────────────────────────────────────────────────────────────────────

run_test() {
    local name="$1" fn="$2"

    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
        return 0
    fi

    local sandbox
    sandbox="$(mktemp -d "$TMPROOT/test.XXXXXX")"
    # Created here, not in the subshell: if the subshell dies before it can
    # create the file, the test must still be reported as a failure.
    : > "$sandbox/failures"

    (
        export SANDBOX="$sandbox"
        export ASSERT_FAILURES="$sandbox/failures"
        export PROXMOX_SLEEP_STATE_DIR="$sandbox/run"
        export MOCK_RUNTIME="$sandbox/runtime"
        export MOCK_CALL_LOG="$sandbox/calls.log"
        export MOCK_BIN_DIR="$MOCKS/container"
        export IDLE_MONITOR_LOG="$sandbox/idle-monitor.log"
        export SLEEP_MANAGER_LOG="$sandbox/sleep-manager.log"
        export CONFIG_FILE="$sandbox/proxmox-sleep.conf"
        export PATH="$MOCKS:$BASE_PATH"

        # Note: $PROXMOX_SLEEP_STATE_DIR is deliberately NOT pre-created — the
        # scripts must create it themselves via `install -d` (mocked to drop
        # the -o/-g flags that need root).
        mkdir -p "$MOCK_RUNTIME"
        : > "$MOCK_CALL_LOG"
        : > "$CONFIG_FILE"

        "$fn"
    ) > "$sandbox/output" 2>&1
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        printf 'test body exited with status %d\n' "$rc" >> "$sandbox/failures"
    fi

    if [[ -s "$sandbox/failures" ]]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  \033[31mFAIL\033[0m  %s\n' "$name"
        sed 's/^/          /' "$sandbox/failures"
        if [[ -s "$sandbox/output" ]]; then
            echo "          --- test output ---"
            sed 's/^/          /' "$sandbox/output" | head -40
        fi
    else
        PASS=$((PASS + 1))
        printf '  \033[32mok\033[0m    %s\n' "$name"
        if [[ "${VERBOSE:-0}" == "1" && -s "$sandbox/output" ]]; then
            sed 's/^/          /' "$sandbox/output"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Legacy single-VM config (backwards compatibility)
# ══════════════════════════════════════════════════════════════════════════════

test_legacy_manager_enumerates_vm() {
    write_config <<'EOF'
VMID=100
VM_NAME="win-game-vm"
EOF
    export MOCK_QM_STATUS_100=running

    local out; out="$(manager status)"
    assert_contains "VM_IDS synthesized from VMID" "$out" "VM IDs: 100"
    assert_contains "legacy VM_NAME honoured"      "$out" "VM 100 (win-game-vm)"
    assert_contains "running state detected"       "$out" "Status:        RUNNING"
    assert_contains "no containers configured"     "$out" "Container IDs: <none>"
    assert_contains "hibernate is the VM default"  "$out" "Sleep action:  hibernate"
}

test_legacy_monitor_enumerates_vm() {
    write_config <<'EOF'
VMID=100
VM_NAME="win-game-vm"
EOF
    export MOCK_QM_STATUS_100=running

    local out; out="$(monitor check)"
    assert_contains "monitor sees legacy VM"  "$out" "VM IDs: 100"
    assert_contains "VM reported running"     "$out" "VM 100 (win-game-vm) [monitor=1]"
    assert_contains "no containers"           "$out" "Container IDs: <none>"
}

test_legacy_gaming_default_preserved() {
    # With GAMING_PROCESSES unset, the legacy shim must install the historical
    # default list rather than an empty one.
    write_config <<'EOF'
VMID=100
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_VM_PROCS_100=$'explorer\nsteam'

    local out; out="$(monitor check)"
    assert_contains "default gaming list active" "$out" "Gaming Processes: DETECTED"
    assert_contains "gaming blocks sleep"        "$out" "Overall Idle Status: ACTIVE"
}

test_legacy_gaming_explicitly_disabled() {
    # The office host sets GAMING_PROCESSES="" on purpose; empty must mean
    # "disabled", not "fall back to the default list".
    write_config <<'EOF'
VMID=100
GAMING_PROCESSES=""
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_VM_PROCS_100=$'explorer\nsteam'

    local out; out="$(monitor check)"
    assert_contains "empty list disables detection" "$out" "Gaming Processes: DISABLED"
    assert_contains "otherwise idle"                "$out" "Overall Idle Status: IDLE"
}

test_legacy_vmid_survives_adding_a_container() {
    # Adding CONTAINER_IDS to a legacy VMID= install must not drop the VM. It
    # used to: hydration required CONTAINER_IDS to be empty too, so the VM went
    # unmanaged and the host suspended with it running.
    write_config <<'EOF'
VMID=100
VM_NAME="win-game-vm"
CONTAINER_IDS="200"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_PCT_STATUS_200=running

    local out; out="$(monitor check)"
    assert_contains "VM still enumerated" "$out" "VM IDs: 100"
    assert_contains "VM still checked"    "$out" "VM 100 (win-game-vm)"
    assert_contains "container too"       "$out" "Container IDs: 200"

    local mout; mout="$(manager status)"
    assert_contains "manager sees the VM" "$mout" "VM IDs: 100"
}

# ══════════════════════════════════════════════════════════════════════════════
# Multi-instance enumeration
# ══════════════════════════════════════════════════════════════════════════════

test_multi_instance_enumeration() {
    write_config <<'EOF'
VM_IDS="100 101"
CONTAINER_IDS="200"
VM_100_NAME="win-game-vm"
VM_101_NAME="second-vm"
CONTAINER_200_NAME="steam-ct"
CONTAINER_200_SLEEP_ACTION="shutdown"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_QM_STATUS_101=stopped
    export MOCK_PCT_STATUS_200=running

    local out; out="$(manager status)"
    assert_contains "both VMs listed"     "$out" "VM IDs: 100 101"
    assert_contains "container listed"    "$out" "Container IDs: 200"
    assert_contains "VM 100 named"        "$out" "VM 100 (win-game-vm)"
    assert_contains "VM 101 named"        "$out" "VM 101 (second-vm)"
    assert_contains "container named"     "$out" "Container 200 (steam-ct)"
    assert_contains "container action"    "$out" "Sleep action:  shutdown"

    local mout; mout="$(monitor check)"
    assert_contains "monitor lists VMs"       "$mout" "VM IDs: 100 101"
    assert_contains "monitor lists container" "$mout" "Container IDs: 200"
    assert_contains "stopped VM reported"     "$mout" "Running: NO"
}

# ══════════════════════════════════════════════════════════════════════════════
# pre-sleep / post-wake state machine
# ══════════════════════════════════════════════════════════════════════════════

test_presleep_records_vm_and_ct() {
    write_config <<'EOF'
VM_IDS="100"
CONTAINER_IDS="200"
VM_100_SLEEP_ACTION="shutdown"
CONTAINER_200_SLEEP_ACTION="shutdown"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_PCT_STATUS_200=running

    manager pre-sleep > /dev/null
    local st; st="$(read_state)"
    assert_contains "VM state recorded" "$st" "vm_100=shutdown"
    assert_contains "CT state recorded" "$st" "ct_200=shutdown"

    local c; c="$(calls)"
    assert_contains "qm shutdown issued"  "$c" "qm shutdown 100"
    assert_contains "pct shutdown issued" "$c" "pct shutdown 200"
}

test_full_cycle_resumes_both() {
    write_config <<'EOF'
VM_IDS="100"
CONTAINER_IDS="200"
VM_100_SLEEP_ACTION="shutdown"
VM_100_RESUME_ON_WAKE="1"
CONTAINER_200_SLEEP_ACTION="shutdown"
CONTAINER_200_RESUME_ON_WAKE="1"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_PCT_STATUS_200=running

    manager pre-sleep > /dev/null
    : > "$MOCK_CALL_LOG"
    manager post-wake > /dev/null

    local c; c="$(calls)"
    assert_contains "VM restarted" "$c" "qm start 100"
    assert_contains "CT restarted" "$c" "pct start 200"

    # State file is consumed by post-wake so a second wake is a no-op.
    assert_eq "state file cleared" "$(read_state)" ""
}

test_stopped_instances_are_not_started_on_wake() {
    # The core requirement: only restart what the sleep hook actually stopped.
    write_config <<'EOF'
VM_IDS="100"
CONTAINER_IDS="200"
VM_100_SLEEP_ACTION="shutdown"
CONTAINER_200_SLEEP_ACTION="shutdown"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_PCT_STATUS_200=stopped   # already off before sleep

    manager pre-sleep > /dev/null
    local st; st="$(read_state)"
    assert_contains "CT recorded as not_running" "$st" "ct_200=not_running"

    : > "$MOCK_CALL_LOG"
    manager post-wake > /dev/null
    local c; c="$(calls)"
    assert_contains     "VM was stopped by us, so restart" "$c" "qm start 100"
    assert_not_contains "CT was already off, leave it"     "$c" "pct start 200"
}

test_resume_on_wake_disabled() {
    write_config <<'EOF'
VM_IDS="100"
CONTAINER_IDS="200"
VM_100_SLEEP_ACTION="shutdown"
CONTAINER_200_SLEEP_ACTION="shutdown"
CONTAINER_200_RESUME_ON_WAKE="0"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_PCT_STATUS_200=running

    manager pre-sleep > /dev/null
    : > "$MOCK_CALL_LOG"
    manager post-wake > /dev/null

    local c; c="$(calls)"
    assert_contains     "VM resumes"                "$c" "qm start 100"
    assert_not_contains "CT honours RESUME_ON_WAKE=0" "$c" "pct start 200"
}

test_keep_running_and_ignore_actions() {
    write_config <<'EOF'
VM_IDS="100 101"
CONTAINER_IDS="200"
VM_100_SLEEP_ACTION="keep_running"
VM_101_SLEEP_ACTION="ignore"
CONTAINER_200_SLEEP_ACTION="keep_running"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_QM_STATUS_101=running
    export MOCK_PCT_STATUS_200=running

    manager pre-sleep > /dev/null
    local st; st="$(read_state)"
    assert_contains "VM 100 kept running" "$st" "vm_100=kept_running"
    assert_contains "VM 101 ignored"      "$st" "vm_101=ignored"
    assert_contains "CT 200 kept running" "$st" "ct_200=kept_running"

    local c; c="$(calls)"
    assert_not_contains "no VM shutdown" "$c" "qm shutdown"
    assert_not_contains "no CT shutdown" "$c" "pct shutdown"

    : > "$MOCK_CALL_LOG"
    manager post-wake > /dev/null
    local c2; c2="$(calls)"
    assert_not_contains "nothing to resume (VM)" "$c2" "qm start"
    assert_not_contains "nothing to resume (CT)" "$c2" "pct start"
}

test_container_hibernate_falls_back_to_shutdown() {
    write_config <<'EOF'
CONTAINER_IDS="200"
CONTAINER_200_SLEEP_ACTION="hibernate"
EOF
    export MOCK_PCT_STATUS_200=running

    local out; out="$(manager pre-sleep)"
    assert_contains "warns about unsupported action" "$out" "hibernate not supported for LXC 200"
    assert_contains "container was shut down"        "$(read_state)" "ct_200=shutdown"
    assert_contains "pct shutdown issued"            "$(calls)" "pct shutdown 200"
}

test_hibernate_success_path() {
    write_config <<'EOF'
VM_IDS="100"
VM_100_SLEEP_ACTION="hibernate"
EOF
    export MOCK_QM_STATUS_100=running
    export HIBERNATE_TIMEOUT=60

    local out; out="$(manager pre-sleep)"
    assert_contains "hibernate command sent" "$(calls)" "shutdown /h"
    assert_contains "confirmed complete"     "$out"     "hibernation confirmed complete"
    assert_contains "state is hibernated"    "$(read_state)" "vm_100=hibernated"
}

test_hibernate_timeout_upserts_single_state_line() {
    # Regression: state_set used to append, leaving both "hibernated" and the
    # post-timeout value in the file, which double-resumed the VM on wake.
    write_config <<'EOF'
VM_IDS="100"
VM_100_SLEEP_ACTION="hibernate"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_VM_HIBERNATE_WORKS_100=0   # VM never stops -> timeout
    export HIBERNATE_TIMEOUT=10

    manager pre-sleep > /dev/null

    local st; st="$(read_state)"
    local count; count="$(grep -c '^vm_100=' <<< "$st")"
    assert_eq "exactly one state line for vm_100" "$count" "1"
    assert_eq "final state is shutdown"           "$st"    "vm_100=shutdown"

    : > "$MOCK_CALL_LOG"
    manager post-wake > /dev/null
    local starts; starts="$(grep -c '^qm start 100' <<< "$(calls)")"
    assert_eq "VM started exactly once" "$starts" "1"
}

test_guest_agent_unresponsive_falls_back_to_shutdown() {
    write_config <<'EOF'
VM_IDS="100"
VM_100_SLEEP_ACTION="hibernate"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_QM_AGENT_100=0

    local out; out="$(manager pre-sleep)"
    assert_contains "warns about agent"    "$out" "Guest agent not responsive"
    assert_contains "fell back to shutdown" "$out" "shut down cleanly via fallback"
    assert_contains "state is shutdown"     "$(read_state)" "vm_100=shutdown"
}

test_forced_stop_is_resumable() {
    # A VM we had to `qm stop` is still something we stopped, so it must come
    # back on wake.
    write_config <<'EOF'
VM_IDS="100"
VM_100_SLEEP_ACTION="shutdown"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_QM_SHUTDOWN_RC_100=1   # graceful shutdown fails

    manager pre-sleep > /dev/null
    assert_contains "recorded as force-stopped" "$(read_state)" "vm_100=was_shutdown"
    assert_contains "force stop issued"         "$(calls)"      "qm stop 100"

    : > "$MOCK_CALL_LOG"
    manager post-wake > /dev/null
    assert_contains "force-stopped VM resumes" "$(calls)" "qm start 100"
}

test_presleep_exit_code_modes() {
    write_config <<'EOF'
VM_IDS="100"
VM_100_SLEEP_ACTION="shutdown"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_QM_SHUTDOWN_RC_100=1

    # systemd hook path: must not abort the sleep transition.
    manager pre-sleep > /dev/null
    assert_rc "pre-sleep is non-blocking by default" "$?" "0"

    # Manual `hibernate` subcommand surfaces the real aggregated result.
    export MOCK_QM_STATUS_100=running
    rm -f "$MOCK_RUNTIME"/qm_status_100
    manager hibernate > /dev/null
    assert_rc "hibernate reports failure" "$?" "1"
}

# ══════════════════════════════════════════════════════════════════════════════
# Gaming process detection
# ══════════════════════════════════════════════════════════════════════════════

test_vm_gaming_exact_match() {
    write_config <<'EOF'
VM_IDS="100"
VM_100_GAMING_PROCESSES="steam.exe"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_VM_PROCS_100=$'explorer\nsteam\nchrome'

    local out; out="$(monitor check)"
    assert_contains "steam.exe matches steam" "$out" "Gaming Processes: DETECTED"
    assert_contains "blocks sleep"            "$out" "Overall Idle Status: ACTIVE"
}

test_vm_gaming_no_substring_match() {
    # Regression: grep -Fqi matched "steamwebhelper" for the pattern "steam".
    write_config <<'EOF'
VM_IDS="100"
VM_100_GAMING_PROCESSES="steam.exe"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_VM_PROCS_100=$'explorer\nsteamwebhelper\nchrome'

    local out; out="$(monitor check)"
    assert_contains "helper alone is not a match" "$out" "Gaming Processes: none"
    assert_contains "host stays idle"             "$out" "Overall Idle Status: IDLE"
}

test_vm_gaming_case_insensitive() {
    write_config <<'EOF'
VM_IDS="100"
VM_100_GAMING_PROCESSES="STEAM.EXE, EpicGamesLauncher.exe"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_VM_PROCS_100=$'Explorer\nSteam'

    local out; out="$(monitor check)"
    assert_contains "case-insensitive match" "$out" "Gaming Processes: DETECTED"
}

test_ct_gaming_via_ps_args() {
    # Exercises the real `ps -eo args=` -> awk -> basename pipeline.
    write_config <<'EOF'
CONTAINER_IDS="200"
CONTAINER_200_GAMING_PROCESSES="steam"
EOF
    export MOCK_PCT_STATUS_200=running
    export MOCK_CT_PS_200=$'/usr/bin/dbus-daemon --session\n/usr/games/steam -silent\n/bin/bash'

    local out; out="$(monitor check)"
    assert_contains "basename of argv[0] matched" "$out" "Gaming Processes: DETECTED"
    assert_contains "container blocks sleep"      "$out" "Overall Idle Status: ACTIVE"
}

test_ct_gaming_long_name_not_truncated() {
    # `ps -eo comm=` truncates to 15 chars (TASK_COMM_LEN); a 20-char process
    # name must still match, which is why the code uses `args=`.
    write_config <<'EOF'
CONTAINER_IDS="200"
CONTAINER_200_GAMING_PROCESSES="steamwebhelperlong20"
EOF
    export MOCK_PCT_STATUS_200=running
    export MOCK_CT_PS_200=$'/usr/lib/steam/steamwebhelperlong20 --type=renderer'

    local out; out="$(monitor check)"
    assert_contains "long process name matched" "$out" "Gaming Processes: DETECTED"
}

test_ct_gaming_no_substring_match() {
    write_config <<'EOF'
CONTAINER_IDS="200"
CONTAINER_200_GAMING_PROCESSES="steam"
EOF
    export MOCK_PCT_STATUS_200=running
    export MOCK_CT_PS_200=$'/usr/lib/steam/steamwebhelper --type=renderer\n/bin/bash'

    local out; out="$(monitor check)"
    assert_contains "helper is not an exact match" "$out" "Gaming Processes: none"
    assert_contains "host stays idle"              "$out" "Overall Idle Status: IDLE"
}

test_ct_gaming_disabled_when_empty() {
    write_config <<'EOF'
CONTAINER_IDS="200"
CONTAINER_200_GAMING_PROCESSES=""
EOF
    export MOCK_PCT_STATUS_200=running
    export MOCK_CT_PS_200=$'/usr/games/steam -silent'

    local out; out="$(monitor check)"
    assert_contains "detection disabled" "$out" "Gaming Processes: DISABLED"
    assert_contains "stays idle"         "$out" "Overall Idle Status: IDLE"
}

# ══════════════════════════════════════════════════════════════════════════════
# Combined host + VM + container idle decision
# ══════════════════════════════════════════════════════════════════════════════

combined_config() {
    write_config <<'EOF'
VM_IDS="100"
CONTAINER_IDS="200"
VM_100_GAMING_PROCESSES="steam.exe"
CONTAINER_200_GAMING_PROCESSES="steam"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_PCT_STATUS_200=running
}

test_combined_vm_gaming_ct_idle() {
    combined_config
    export MOCK_VM_PROCS_100=$'explorer\nsteam'
    export MOCK_CT_PS_200=$'/bin/bash'

    assert_contains "VM activity wins" "$(monitor check)" "Overall Idle Status: ACTIVE"
}

test_combined_vm_idle_ct_gaming() {
    combined_config
    export MOCK_VM_PROCS_100=$'explorer'
    export MOCK_CT_PS_200=$'/usr/games/steam -silent'

    assert_contains "CT activity wins" "$(monitor check)" "Overall Idle Status: ACTIVE"
}

test_combined_both_idle() {
    combined_config
    export MOCK_VM_PROCS_100=$'explorer'
    export MOCK_CT_PS_200=$'/bin/bash'

    assert_contains "both idle -> idle" "$(monitor check)" "Overall Idle Status: IDLE"
}

test_combined_cpu_thresholds() {
    combined_config
    export MOCK_VM_PROCS_100=$'explorer'
    export MOCK_CT_PS_200=$'/bin/bash'
    export MOCK_CT_CPU_200=0.85   # 85% -> above the 15% default

    local out; out="$(monitor check)"
    assert_contains "container CPU reported" "$out" "CPU Usage: 85%"
    assert_contains "busy container blocks"  "$out" "Overall Idle Status: ACTIVE"
}

test_per_instance_threshold_override() {
    combined_config
    export MOCK_VM_PROCS_100=$'explorer'
    export MOCK_CT_PS_200=$'/bin/bash'
    export MOCK_CT_CPU_200=0.40

    # Default threshold (15%) would call this active; the override must not.
    echo 'CONTAINER_200_CPU_IDLE_THRESHOLD="50"' >> "$CONFIG_FILE"

    assert_contains "override raises the bar" "$(monitor check)" "Overall Idle Status: IDLE"
}

test_monitor_flag_excludes_instance() {
    combined_config
    export MOCK_VM_PROCS_100=$'explorer\nsteam'   # would otherwise block
    export MOCK_CT_PS_200=$'/bin/bash'
    echo 'VM_100_MONITOR="0"' >> "$CONFIG_FILE"

    local out; out="$(monitor check)"
    assert_contains "VM shown as unmonitored" "$out" "[monitor=0]"
    assert_contains "unmonitored VM ignored"  "$out" "Overall Idle Status: IDLE"
}

# ══════════════════════════════════════════════════════════════════════════════
# Host-side GPU handling for containers (vfio-pci safety)
# ══════════════════════════════════════════════════════════════════════════════

test_ct_gpu_absent_binary_is_not_active() {
    # The critical vfio case: while the Windows VM owns the GPU, host-side
    # nvidia-smi is missing or blind. That must never read as "active".
    write_config <<'EOF'
CONTAINER_IDS="200"
EOF
    export MOCK_PCT_STATUS_200=running
    # nvidia-smi deliberately not on PATH

    local out; out="$(monitor check)"
    assert_contains "sentinel reported" "$out" "Host GPU Usage: -1%"
    assert_contains "sentinel is idle"  "$out" "Overall Idle Status: IDLE"
}

test_ct_gpu_error_is_not_active() {
    write_config <<'EOF'
CONTAINER_IDS="200"
EOF
    export MOCK_PCT_STATUS_200=running
    with_nvidia
    export MOCK_NVIDIA_RC=9   # "No devices were found"

    local out; out="$(monitor check)"
    assert_contains "error maps to sentinel" "$out" "Host GPU Usage: -1%"
    assert_contains "still idle"             "$out" "Overall Idle Status: IDLE"
}

test_ct_gpu_takes_max_across_gpus() {
    # Regression: only GPU 0 was read, so load on a second GPU was missed.
    write_config <<'EOF'
CONTAINER_IDS="200"
EOF
    export MOCK_PCT_STATUS_200=running
    with_nvidia
    export MOCK_NVIDIA_OUTPUT=$'0\n85'

    local out; out="$(monitor check)"
    assert_contains "max across GPUs" "$out" "Host GPU Usage: 85%"
    assert_contains "busy GPU blocks" "$out" "Overall Idle Status: ACTIVE"
}

test_ct_gpu_idle_across_gpus() {
    write_config <<'EOF'
CONTAINER_IDS="200"
EOF
    export MOCK_PCT_STATUS_200=running
    with_nvidia
    export MOCK_NVIDIA_OUTPUT=$'0\n3'

    local out; out="$(monitor check)"
    assert_contains "low usage reported" "$out" "Host GPU Usage: 3%"
    assert_contains "below threshold"    "$out" "Overall Idle Status: IDLE"
}

test_ct_gpu_queried_once_per_cycle() {
    write_config <<'EOF'
CONTAINER_IDS="200 201"
EOF
    export MOCK_PCT_STATUS_200=running
    export MOCK_PCT_STATUS_201=running
    with_nvidia
    export MOCK_NVIDIA_OUTPUT="0"

    monitor check > /dev/null
    # check_once prints the value per container (2 calls) and is_system_idle
    # caches it for the whole cycle (1 more) -> 3, not 4.
    local n; n="$(grep -c '^nvidia-smi' <<< "$(calls)")"
    assert_eq "nvidia-smi cached within is_system_idle" "$n" "3"
}

# ══════════════════════════════════════════════════════════════════════════════
# Host-level gates
# ══════════════════════════════════════════════════════════════════════════════

test_host_blocking_process_blocks_sleep() {
    write_config <<'EOF'
VM_IDS="100"
HOST_BLOCKING_PROCESSES="unattended-upgrade"
EOF
    export MOCK_QM_STATUS_100=stopped
    export MOCK_RUNNING_PROCS="unattended-upgrade"

    local out; out="$(monitor check)"
    assert_contains "process detected" "$out" "Host Blocking Processes: DETECTED"
    assert_contains "blocks sleep"     "$out" "Overall Idle Status: ACTIVE"
}

test_host_blocking_unit_blocks_sleep() {
    write_config <<'EOF'
VM_IDS="100"
HOST_BLOCKING_UNITS="apt-daily.service,apt-daily-upgrade.service"
EOF
    export MOCK_QM_STATUS_100=stopped
    export MOCK_ACTIVE_UNITS="apt-daily-upgrade.service"

    local out; out="$(monitor check)"
    assert_contains "unit detected" "$out" "Host Blocking Units: ACTIVE"
    assert_contains "blocks sleep"  "$out" "Overall Idle Status: ACTIVE"
}

test_ssh_session_blocks_sleep() {
    write_config <<'EOF'
VM_IDS="100"
EOF
    export MOCK_QM_STATUS_100=stopped
    export MOCK_WHO="admin    pts/0        2026-07-27 09:00 (10.0.0.5)"

    local out; out="$(monitor check)"
    assert_contains "session detected" "$out" "SSH Sessions: YES"
    assert_contains "blocks sleep"     "$out" "Overall Idle Status: ACTIVE"
}

test_sleep_inhibitor_blocks_sleep() {
    # Real `systemd-inhibit --list --no-legend` layout: WHO UID USER PID COMM
    # WHAT WHY MODE, with a multi-word WHO and WHY. A fixed field index cannot
    # find WHAT here, which is the whole point of the case.
    write_config <<'EOF'
VM_IDS="100"
EOF
    export MOCK_QM_STATUS_100=stopped
    export MOCK_INHIBITORS="Backup Service 0 root 1234 backup-runner sleep:shutdown Backup in progress block"

    local out; out="$(monitor check)"
    assert_contains "inhibitor detected" "$out" "Sleep Inhibitors: ACTIVE"
    assert_contains "names the holder"   "$out" "Backup Service"
    assert_contains "blocks sleep"       "$out" "Overall Idle Status: ACTIVE"
}

test_non_sleep_inhibitor_does_not_block() {
    # A shutdown-only inhibitor must not hold off sleep. This is the line a
    # stock Debian host actually carries, verbatim from systemd 259.
    write_config <<'EOF'
VM_IDS="100"
EOF
    export MOCK_QM_STATUS_100=stopped
    export MOCK_INHIBITORS="Unattended Upgrades Shutdown 0 root 344 unattended-upgr shutdown Stop ongoing upgrades or perform upgrades before shutdown delay"

    local out; out="$(monitor check)"
    assert_contains "no sleep inhibitor" "$out" "Sleep Inhibitors: none"
    assert_contains "still idle"         "$out" "Overall Idle Status: IDLE"
}

# ══════════════════════════════════════════════════════════════════════════════
# Wake-time bookkeeping
# ══════════════════════════════════════════════════════════════════════════════

test_corrupt_wake_file_is_repaired() {
    # Regression: a non-numeric wake file crashed the daemon under `set -u`.
    write_config <<'EOF'
VM_IDS="100"
VM_100_CHECK_USER_IDLE="1"
EOF
    export MOCK_QM_STATUS_100=running

    mkdir -p "$PROXMOX_SLEEP_STATE_DIR"
    printf 'not-a-timestamp\n' > "$PROXMOX_SLEEP_STATE_DIR/idle-monitor.wake"

    local out rc
    out="$(monitor check)"; rc=$?
    assert_rc "monitor survives corrupt wake file" "$rc" "0"
    # The message must reach stderr, not stdout: get_seconds_since_wake's
    # stdout is its return value, so logging inline would corrupt the sentinel
    # the callers parse.
    assert_contains "logs the repair" "$out" "Invalid wake timestamp"
    assert_contains "sentinel stays parseable" "$out" "Effective Idle Time: 99999s"

    local repaired; repaired="$(cat "$PROXMOX_SLEEP_STATE_DIR/idle-monitor.wake")"
    [[ "$repaired" =~ ^[0-9]+$ ]] || fail_assert "wake file not rewritten with a timestamp (got '$repaired')"

    # And it must be persisted to the log file as well as stderr.
    grep -q "Invalid wake timestamp" "$IDLE_MONITOR_LOG" ||
        fail_assert "repair message missing from $IDLE_MONITOR_LOG"
}

test_post_wake_resets_idle_tracking() {
    write_config <<'EOF'
VM_IDS="100"
VM_100_SLEEP_ACTION="shutdown"
EOF
    export MOCK_QM_STATUS_100=running

    manager pre-sleep > /dev/null

    # Simulate an idle-monitor state file left over from before the sleep.
    printf '1000000000\n' > "$PROXMOX_SLEEP_STATE_DIR/idle-monitor.state"

    manager post-wake > /dev/null

    [[ -f "$PROXMOX_SLEEP_STATE_DIR/idle-monitor.state" ]] &&
        fail_assert "stale idle state should be cleared on wake"
    [[ -f "$PROXMOX_SLEEP_STATE_DIR/idle-monitor.wake" ]] ||
        fail_assert "wake timestamp should be recorded on wake"
}

test_effective_idle_clamped_to_time_since_wake() {
    # Windows may report a huge idle time right after a wake; the effective
    # value must be clamped so a just-woken host is never treated as long-idle.
    write_config <<'EOF'
VM_IDS="100"
VM_100_CHECK_USER_IDLE="1"
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_VM_IDLE_100=99999

    mkdir -p "$PROXMOX_SLEEP_STATE_DIR"
    date +%s > "$PROXMOX_SLEEP_STATE_DIR/idle-monitor.wake"

    local out; out="$(monitor check)"
    assert_contains "raw Windows idle is large" "$out" "Windows Idle Time: 99999s"
    assert_contains "recent wake reads active"  "$out" "Overall Idle Status: ACTIVE"

    # Clamped to seconds-since-wake, which is ~0 but races with the clock, so
    # assert the bound rather than an exact second.
    local eff
    eff="$(sed -n 's/.*Effective Idle Time: \([0-9-]*\)s.*/\1/p' <<< "$out")"
    if [[ ! "$eff" =~ ^[0-9]+$ ]] || (( eff >= 60 )); then
        fail_assert "effective idle should be clamped below CHECK_INTERVAL, got '$eff'"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Config validation
# ══════════════════════════════════════════════════════════════════════════════

test_no_instances_configured_is_a_config_error() {
    write_config <<'EOF'
# deliberately empty
EOF
    local out rc
    out="$(bash "$MONITOR" start 2>&1)"; rc=$?
    assert_rc "exits with EX_CONFIG"  "$rc" "78"
    assert_contains "explains itself" "$out" "No VMs or containers configured"
}

test_bad_idle_threshold_is_a_config_error() {
    write_config <<'EOF'
VM_IDS="100"
IDLE_THRESHOLD_MINUTES="soon"
EOF
    export MOCK_QM_STATUS_100=running

    local out rc
    out="$(bash "$MONITOR" start 2>&1)"; rc=$?
    assert_rc "exits with EX_CONFIG"   "$rc" "78"
    assert_contains "names the setting" "$out" "IDLE_THRESHOLD_MINUTES must be a non-negative integer"
}

test_bad_sleep_action_is_a_config_error() {
    # An unrecognised action used to fall through to "ignore", leaving a
    # passthrough VM running while the host suspended.
    write_config <<'EOF'
VM_IDS="100"
VM_100_SLEEP_ACTION=hibernte
EOF
    export MOCK_QM_STATUS_100=running

    local out rc
    out="$(bash "$MONITOR" start 2>&1)"; rc=$?
    assert_rc "exits with EX_CONFIG"    "$rc" "78"
    assert_contains "names the setting" "$out" "VM_100_SLEEP_ACTION='hibernte'"
    assert_contains "lists valid values" "$out" "hibernate, shutdown, keep_running, ignore"
}

test_invalid_sleep_action_flagged_in_status() {
    write_config <<'EOF'
VM_IDS="100"
VM_100_SLEEP_ACTION=hibernte
EOF
    export MOCK_QM_STATUS_100=running

    local out; out="$(manager status)"
    assert_contains "marks it invalid" "$out" "INVALID"
}

test_zero_idle_threshold_status_reports_disabled() {
    write_config <<'EOF'
VM_IDS="100"
IDLE_THRESHOLD_MINUTES=0
EOF
    export MOCK_QM_STATUS_100=running
    export MOCK_VM_PROCS_100=$'explorer'

    local out; out="$(monitor status)"
    assert_contains     "says auto-sleep is off" "$out" "Auto-sleep: DISABLED"
    assert_not_contains "promises no countdown"  "$out" "Will start on next check"
}

test_missing_config_file_is_a_config_error() {
    rm -f "$CONFIG_FILE"
    local out rc
    out="$(bash "$MONITOR" start 2>&1)"; rc=$?
    assert_rc "exits with EX_CONFIG"  "$rc" "78"
    assert_contains "points at the example" "$out" "Configuration file not found"
}

# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Proxmox Sleep Manager — offline test suite"
echo "==========================================="
echo ""

run_test "legacy/manager-enumerates-vm"          test_legacy_manager_enumerates_vm
run_test "legacy/monitor-enumerates-vm"          test_legacy_monitor_enumerates_vm
run_test "legacy/gaming-default-preserved"       test_legacy_gaming_default_preserved
run_test "legacy/gaming-explicitly-disabled"     test_legacy_gaming_explicitly_disabled
run_test "legacy/vmid-plus-container"            test_legacy_vmid_survives_adding_a_container

run_test "multi/enumeration"                     test_multi_instance_enumeration

run_test "cycle/presleep-records-vm-and-ct"      test_presleep_records_vm_and_ct
run_test "cycle/full-cycle-resumes-both"         test_full_cycle_resumes_both
run_test "cycle/stopped-instances-not-started"   test_stopped_instances_are_not_started_on_wake
run_test "cycle/resume-on-wake-disabled"         test_resume_on_wake_disabled
run_test "cycle/keep-running-and-ignore"         test_keep_running_and_ignore_actions
run_test "cycle/ct-hibernate-falls-back"         test_container_hibernate_falls_back_to_shutdown
run_test "cycle/hibernate-success"               test_hibernate_success_path
run_test "cycle/hibernate-timeout-upsert"        test_hibernate_timeout_upserts_single_state_line
run_test "cycle/agent-unresponsive-fallback"     test_guest_agent_unresponsive_falls_back_to_shutdown
run_test "cycle/forced-stop-is-resumable"        test_forced_stop_is_resumable
run_test "cycle/presleep-exit-code-modes"        test_presleep_exit_code_modes

run_test "gaming/vm-exact-match"                 test_vm_gaming_exact_match
run_test "gaming/vm-no-substring-match"          test_vm_gaming_no_substring_match
run_test "gaming/vm-case-insensitive"            test_vm_gaming_case_insensitive
run_test "gaming/ct-via-ps-args"                 test_ct_gaming_via_ps_args
run_test "gaming/ct-long-name-not-truncated"     test_ct_gaming_long_name_not_truncated
run_test "gaming/ct-no-substring-match"          test_ct_gaming_no_substring_match
run_test "gaming/ct-disabled-when-empty"         test_ct_gaming_disabled_when_empty

run_test "combined/vm-gaming-ct-idle"            test_combined_vm_gaming_ct_idle
run_test "combined/vm-idle-ct-gaming"            test_combined_vm_idle_ct_gaming
run_test "combined/both-idle"                    test_combined_both_idle
run_test "combined/cpu-thresholds"               test_combined_cpu_thresholds
run_test "combined/per-instance-threshold"       test_per_instance_threshold_override
run_test "combined/monitor-flag-excludes"        test_monitor_flag_excludes_instance

run_test "gpu/ct-absent-binary-not-active"       test_ct_gpu_absent_binary_is_not_active
run_test "gpu/ct-error-not-active"               test_ct_gpu_error_is_not_active
run_test "gpu/ct-max-across-gpus"                test_ct_gpu_takes_max_across_gpus
run_test "gpu/ct-idle-across-gpus"               test_ct_gpu_idle_across_gpus
run_test "gpu/ct-queried-once-per-cycle"         test_ct_gpu_queried_once_per_cycle

run_test "host/blocking-process"                 test_host_blocking_process_blocks_sleep
run_test "host/blocking-unit"                    test_host_blocking_unit_blocks_sleep
run_test "host/ssh-session"                      test_ssh_session_blocks_sleep
run_test "host/sleep-inhibitor"                  test_sleep_inhibitor_blocks_sleep
run_test "host/non-sleep-inhibitor-ignored"      test_non_sleep_inhibitor_does_not_block

run_test "wake/corrupt-wake-file-repaired"       test_corrupt_wake_file_is_repaired
run_test "wake/post-wake-resets-idle-tracking"   test_post_wake_resets_idle_tracking
run_test "wake/effective-idle-clamped"           test_effective_idle_clamped_to_time_since_wake

run_test "config/no-instances"                   test_no_instances_configured_is_a_config_error
run_test "config/bad-idle-threshold"             test_bad_idle_threshold_is_a_config_error
run_test "config/bad-sleep-action"               test_bad_sleep_action_is_a_config_error
run_test "config/invalid-action-in-status"       test_invalid_sleep_action_flagged_in_status
run_test "config/threshold-zero-disables"        test_zero_idle_threshold_status_reports_disabled
run_test "config/missing-file"                   test_missing_config_file_is_a_config_error

echo ""
echo "-------------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "failing tests:"
    printf '  %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
echo ""
exit 0
