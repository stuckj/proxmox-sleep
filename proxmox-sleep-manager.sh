#!/bin/bash
#
# Proxmox Sleep Manager
# Manages Windows VM hibernation when host sleeps/wakes
#

# Load configuration file if it exists
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-sleep.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Configuration (env vars override config file, defaults as fallback)
VMID="${PROXMOX_VMID:-${VMID:-100}}"
VM_NAME="${PROXMOX_VM_NAME:-${VM_NAME:-windows-vm}}"
HIBERNATE_TIMEOUT="${HIBERNATE_TIMEOUT:-300}"
WAKE_DELAY="${WAKE_DELAY:-5}"
LOG_FILE="${SLEEP_MANAGER_LOG:-/var/log/proxmox-sleep-manager.log}"
STATE_FILE="/tmp/proxmox-sleep-manager.state"

# Logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Check if VM is running
vm_is_running() {
    local status
    status=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
    [[ "$status" == "running" ]]
}

# Check if guest agent is responsive
guest_agent_ready() {
    qm guest cmd "$VMID" ping &>/dev/null
}

# Wait for guest agent to be ready
wait_for_guest_agent() {
    local max_wait=${1:-60}
    local waited=0

    log "Waiting for guest agent (max ${max_wait}s)..."
    while [[ $waited -lt $max_wait ]]; do
        if guest_agent_ready; then
            log "Guest agent is responsive"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    log "Guest agent not responsive after ${max_wait}s"
    return 1
}

# Get Windows power state via guest agent
get_windows_power_state() {
    # Try to execute a simple command - if it works, Windows is awake
    if qm guest exec "$VMID" -- powershell -Command "echo 'awake'" &>/dev/null; then
        echo "awake"
    else
        echo "unknown"
    fi
}

# Hibernate Windows VM via guest agent
hibernate_vm() {
    log "Initiating Windows hibernation for VM $VMID ($VM_NAME)..."

    if ! vm_is_running; then
        log "VM is not running, nothing to hibernate"
        echo "not_running" > "$STATE_FILE"
        return 0
    fi

    if ! guest_agent_ready; then
        log "WARNING: Guest agent not responsive, attempting shutdown instead"
        qm shutdown "$VMID" --timeout 120
        echo "was_shutdown" > "$STATE_FILE"
        return $?
    fi

    # Record that VM was running and we're hibernating it
    echo "hibernated" > "$STATE_FILE"

    # Send hibernate command to Windows
    # Using shutdown /h which triggers hibernation
    log "Sending hibernate command to Windows..."
    if ! qm guest exec "$VMID" -- cmd /c "shutdown /h" &>/dev/null; then
        log "WARNING: Hibernate command may have failed (exit code: $?)"
    fi

    # Wait for VM to actually stop (hibernation completes)
    # We need to confirm it stays stopped to avoid race conditions
    local waited=0
    local consecutive_stopped=0
    local required_stopped=3  # Require 3 consecutive "stopped" checks (15 seconds)

    while [[ $waited -lt $HIBERNATE_TIMEOUT ]]; do
        sleep 5
        waited=$((waited + 5))

        local current_status
        current_status=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
        log "VM status after ${waited}s: $current_status"

        if [[ "$current_status" != "running" ]]; then
            consecutive_stopped=$((consecutive_stopped + 1))
            log "VM not running (check $consecutive_stopped of $required_stopped)"

            if [[ $consecutive_stopped -ge $required_stopped ]]; then
                # Double-check QEMU process is gone
                if ! pgrep -f "qemu.*-id $VMID " > /dev/null 2>&1; then
                    log "VM hibernation confirmed complete (took ${waited}s)"
                    return 0
                else
                    log "QEMU process still exists, continuing to wait..."
                    consecutive_stopped=0
                fi
            fi
        else
            consecutive_stopped=0
            log "Still waiting for hibernation..."
        fi
    done

    log "ERROR: Hibernation timeout after ${HIBERNATE_TIMEOUT}s"
    log "Attempting graceful shutdown..."
    qm shutdown "$VMID" --timeout 60
    echo "was_shutdown" > "$STATE_FILE"
    return 1
}

# Resume VM after host wake
resume_vm() {
    log "Host waking up, checking if VM should be resumed..."

    if [[ ! -f "$STATE_FILE" ]]; then
        log "No state file found, not starting VM"
        return 0
    fi

    local prev_state
    prev_state=$(cat "$STATE_FILE")
    rm -f "$STATE_FILE"

    case "$prev_state" in
        hibernated|was_shutdown)
            log "VM was $prev_state before sleep"

            # Check if VM is already running (shouldn't happen, but handle it)
            if vm_is_running; then
                log "WARNING: VM is already running - hibernation may not have completed"
                log "Waiting to see if VM stops (hibernation completing)..."

                # Wait up to 60 seconds for hibernation to complete
                local wait_count=0
                while vm_is_running && [[ $wait_count -lt 12 ]]; do
                    sleep 5
                    wait_count=$((wait_count + 1))
                    local elapsed_seconds=$((wait_count * 5))
                    log "VM still running, waiting... (${elapsed_seconds}s)"
                done

                if vm_is_running; then
                    log "VM remained running - assuming it's operational"
                    return 0
                else
                    log "VM stopped (hibernation completed late), now starting..."
                fi
            fi

            sleep "$WAKE_DELAY"  # Give system time to stabilize
            qm start "$VMID"
            local start_status=$?

            if [[ $start_status -eq 0 ]]; then
                log "VM start command issued successfully"
                # VM will resume from hibernation automatically
            else
                log "ERROR: Failed to start VM (may already be running)"
                # Check if it's running anyway
                if vm_is_running; then
                    log "VM is running, continuing normally"
                    return 0
                fi
                return 1
            fi
            ;;
        not_running)
            log "VM was not running before sleep, leaving it stopped"
            ;;
        *)
            log "Unknown previous state: $prev_state"
            ;;
    esac

    return 0
}

# Pre-sleep hook (called before system sleeps)
pre_sleep() {
    log "=== PRE-SLEEP HOOK TRIGGERED ==="
    hibernate_vm
    local result=$?
    log "=== PRE-SLEEP HOOK COMPLETE (exit: $result) ==="
    return $result
}

# Post-wake hook (called after system wakes)
post_wake() {
    log "=== POST-WAKE HOOK TRIGGERED ==="
    resume_vm
    local result=$?
    log "=== POST-WAKE HOOK COMPLETE (exit: $result) ==="
    return $result
}

# Show status
status() {
    echo "Proxmox Sleep Manager Status"
    echo "============================="
    echo "VM ID: $VMID"
    echo "VM Name: $VM_NAME"
    echo ""

    if vm_is_running; then
        echo "VM Status: RUNNING"
        if guest_agent_ready; then
            echo "Guest Agent: RESPONSIVE"
        else
            echo "Guest Agent: NOT RESPONDING"
        fi
    else
        echo "VM Status: STOPPED"
    fi

    echo ""
    if [[ -f "$STATE_FILE" ]]; then
        echo "Pending State: $(cat "$STATE_FILE")"
    else
        echo "Pending State: none"
    fi

    echo ""
    echo "Recent Log:"
    tail -20 "$LOG_FILE" 2>/dev/null || echo "(no logs yet)"
}

# Main
case "${1:-}" in
    pre-sleep)
        pre_sleep
        ;;
    post-wake)
        post_wake
        ;;
    hibernate)
        hibernate_vm
        ;;
    resume)
        resume_vm
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {pre-sleep|post-wake|hibernate|resume|status}"
        echo ""
        echo "Commands:"
        echo "  pre-sleep  - Hibernate VM before system sleep"
        echo "  post-wake  - Resume VM after system wake"
        echo "  hibernate  - Manually hibernate the VM"
        echo "  resume     - Manually resume/start the VM"
        echo "  status     - Show current status"
        echo ""
        echo "Configuration:"
        echo "  Config file: /etc/proxmox-sleep.conf"
        echo "  See proxmox-sleep.conf.example for all options"
        exit 1
        ;;
esac
