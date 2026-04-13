#!/bin/bash
#
# Proxmox Sleep Manager
# Manages VM hibernation and LXC container shutdown when host sleeps/wakes.
# Supports multiple VMs and containers — see proxmox-sleep.conf.example.
#

# Load configuration file if it exists
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-sleep.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Global settings (env vars override config file, defaults as fallback)
HIBERNATE_TIMEOUT="${HIBERNATE_TIMEOUT:-300}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-120}"
WAKE_DELAY="${WAKE_DELAY:-5}"
LOG_FILE="${SLEEP_MANAGER_LOG:-/var/log/proxmox-sleep-manager.log}"

# Runtime state lives under /run/proxmox-sleep, a root-owned tmpfs directory.
# Using /run instead of /tmp avoids symlink-planting attacks by unprivileged
# users (everything here is written as root via `>`).
STATE_DIR="/run/proxmox-sleep"
install -d -m 0755 -o root -g root "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/sleep-manager.state"

# Logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Read a config var with a default (uses bash indirect expansion)
get_cfg() {
    local var="$1" default="${2:-}"
    local val="${!var-}"
    echo "${val:-$default}"
}

# Hydrate legacy single-VM config into the multi-instance form when needed.
# If the user's config still sets only the old VMID= / VM_NAME= / GAMING_PROCESSES=
# variables and no VM_IDS / CONTAINER_IDS, synthesize a single VM entry.
hydrate_legacy_config() {
    VM_IDS="${VM_IDS:-}"
    CONTAINER_IDS="${CONTAINER_IDS:-}"
    if [[ -z "$VM_IDS" && -z "$CONTAINER_IDS" && -n "${VMID:-}" ]]; then
        VM_IDS="$VMID"
        printf -v "VM_${VMID}_NAME"            '%s' "${VM_NAME:-windows-vm}"
        printf -v "VM_${VMID}_MONITOR"         '%s' "1"
        printf -v "VM_${VMID}_SLEEP_ACTION"    '%s' "hibernate"
        printf -v "VM_${VMID}_RESUME_ON_WAKE"  '%s' "1"
        printf -v "VM_${VMID}_GAMING_PROCESSES" '%s' "${GAMING_PROCESSES:-}"
        printf -v "VM_${VMID}_CHECK_POWER_REQUESTS" '%s' "1"
        printf -v "VM_${VMID}_CHECK_USER_IDLE" '%s' "1"
    fi
}
hydrate_legacy_config

# --- VM / CT status helpers -------------------------------------------------

vm_is_running() {
    local id="$1" status
    status=$(qm status "$id" 2>/dev/null | awk '{print $2}')
    [[ "$status" == "running" ]]
}

ct_is_running() {
    local id="$1" status
    # `pct status <id>` prints "status: running" or "status: stopped"
    status=$(pct status "$id" 2>/dev/null | awk '{print $2}')
    [[ "$status" == "running" ]]
}

instance_is_running() {
    local kind="$1" id="$2"
    case "$kind" in
        vm) vm_is_running "$id" ;;
        ct) ct_is_running "$id" ;;
    esac
}

# Check if guest agent is responsive for a given VM id
guest_agent_ready() {
    local id="$1"
    qm guest cmd "$id" ping &>/dev/null
}

# --- State file helpers -----------------------------------------------------

state_set() {
    # Upsert key=value into state file. Removes any prior entry for the same
    # key before appending the new value, so each instance has exactly one
    # final state record even if multiple code paths write during pre_sleep
    # (e.g., hibernate_vm writes "hibernated" then "was_shutdown" on timeout).
    local key="$1" value="$2"
    if [[ -f "$STATE_FILE" ]]; then
        sed -i "/^${key}=/d" "$STATE_FILE"
    fi
    echo "${key}=${value}" >> "$STATE_FILE"
}

# --- Hibernate / shutdown / resume per instance -----------------------------

# Hibernate a single Windows VM. State key values used across all sleep paths:
#   hibernated | shutdown | was_shutdown | not_running | kept_running | ignored
hibernate_vm() {
    local id="$1"
    local name; name=$(get_cfg "VM_${id}_NAME" "vm-${id}")
    log "Initiating Windows hibernation for VM $id ($name)..."

    if ! vm_is_running "$id"; then
        log "VM $id not running, nothing to hibernate"
        state_set "vm_${id}" "not_running"
        return 0
    fi

    if ! guest_agent_ready "$id"; then
        log "WARNING: Guest agent not responsive for VM $id, attempting shutdown instead"
        if qm shutdown "$id" --timeout "$SHUTDOWN_TIMEOUT" &>/dev/null; then
            log "VM $id shut down cleanly via fallback"
            state_set "vm_${id}" "shutdown"
            return 0
        fi
        log "WARNING: Graceful shutdown failed for VM $id, forcing stop"
        qm stop "$id" &>/dev/null || true
        state_set "vm_${id}" "was_shutdown"
        return 1
    fi

    state_set "vm_${id}" "hibernated"

    log "Sending hibernate command to VM $id..."
    if ! qm guest exec "$id" -- cmd /c "shutdown /h" &>/dev/null; then
        log "WARNING: Hibernate command may have failed for VM $id"
    fi

    local waited=0 consecutive_stopped=0
    local required_stopped=3
    while [[ $waited -lt $HIBERNATE_TIMEOUT ]]; do
        sleep 5
        waited=$((waited + 5))

        local current_status
        current_status=$(qm status "$id" 2>/dev/null | awk '{print $2}')
        log "VM $id status after ${waited}s: $current_status"

        if [[ "$current_status" != "running" ]]; then
            consecutive_stopped=$((consecutive_stopped + 1))
            log "VM $id not running (check $consecutive_stopped of $required_stopped)"
            if [[ $consecutive_stopped -ge $required_stopped ]]; then
                if ! pgrep -f "qemu.*-id $id " > /dev/null 2>&1; then
                    log "VM $id hibernation confirmed complete (took ${waited}s)"
                    return 0
                else
                    log "QEMU process for VM $id still exists, continuing to wait..."
                    consecutive_stopped=0
                fi
            fi
        else
            consecutive_stopped=0
        fi
    done

    log "ERROR: Hibernation timeout after ${HIBERNATE_TIMEOUT}s for VM $id; attempting graceful shutdown"
    if qm shutdown "$id" --timeout "$SHUTDOWN_TIMEOUT" &>/dev/null; then
        log "VM $id shut down cleanly after hibernation timeout"
        state_set "vm_${id}" "shutdown"
        # Hibernation failed, but the VM is cleanly stopped and the host can
        # safely sleep — from the caller's point of view the pre-sleep action
        # succeeded. Return non-zero only if we couldn't stop the VM cleanly.
        return 0
    fi
    log "ERROR: VM $id shutdown failed after hibernation timeout; forcing stop"
    qm stop "$id" &>/dev/null || true
    state_set "vm_${id}" "was_shutdown"
    return 1
}

# Cleanly shut down a VM (sleep_action=shutdown). State values: see hibernate_vm.
shutdown_vm() {
    local id="$1"
    local name; name=$(get_cfg "VM_${id}_NAME" "vm-${id}")
    log "Shutting down VM $id ($name)..."

    if ! vm_is_running "$id"; then
        log "VM $id not running, nothing to do"
        state_set "vm_${id}" "not_running"
        return 0
    fi

    # `qm shutdown --timeout N` already blocks until the VM stops or N seconds
    # elapse, so we trust its exit code rather than polling afterwards (which
    # would double the worst-case wait).
    if qm shutdown "$id" --timeout "$SHUTDOWN_TIMEOUT" &>/dev/null; then
        log "VM $id shut down cleanly"
        state_set "vm_${id}" "shutdown"
        return 0
    fi

    log "ERROR: VM $id shutdown timeout or failure; forcing stop"
    qm stop "$id" &>/dev/null || true
    state_set "vm_${id}" "was_shutdown"
    return 1
}

# Shut down an LXC container. State values: see hibernate_vm.
shutdown_ct() {
    local id="$1"
    local name; name=$(get_cfg "CONTAINER_${id}_NAME" "ct-${id}")
    log "Shutting down container $id ($name)..."

    if ! ct_is_running "$id"; then
        log "Container $id not running, nothing to do"
        state_set "ct_${id}" "not_running"
        return 0
    fi

    # `pct shutdown --timeout N` already blocks until the container stops or
    # N seconds elapse, so we trust its exit code rather than polling
    # afterwards (which would double the worst-case wait).
    if pct shutdown "$id" --timeout "$SHUTDOWN_TIMEOUT" &>/dev/null; then
        log "Container $id shut down cleanly"
        state_set "ct_${id}" "shutdown"
        return 0
    fi

    log "ERROR: Container $id shutdown timeout or failure; forcing stop"
    pct stop "$id" &>/dev/null || true
    state_set "ct_${id}" "was_shutdown"
    return 1
}

# Start a stopped instance (called from post_wake for resumable states)
resume_instance() {
    local kind="$1" id="$2"
    local label name
    case "$kind" in
        vm) label="VM"        ; name=$(get_cfg "VM_${id}_NAME"        "vm-${id}") ;;
        ct) label="Container" ; name=$(get_cfg "CONTAINER_${id}_NAME" "ct-${id}") ;;
    esac

    log "Resuming $label $id ($name)..."

    # Race handling: if the instance is already running (e.g., VM finishing late
    # hibernation), wait briefly for it to stop, then start it.
    if instance_is_running "$kind" "$id"; then
        log "WARNING: $label $id is already running — hibernation may not have completed"
        local wait_count=0
        while instance_is_running "$kind" "$id" && [[ $wait_count -lt 12 ]]; do
            sleep 5
            wait_count=$((wait_count + 1))
            log "$label $id still running, waiting... ($((wait_count * 5))s)"
        done
        if instance_is_running "$kind" "$id"; then
            log "$label $id remained running — assuming it's operational"
            return 0
        else
            log "$label $id stopped (hibernation completed late), now starting..."
        fi
    fi

    sleep "$WAKE_DELAY"
    local rc
    case "$kind" in
        vm) qm start "$id"  ; rc=$? ;;
        ct) pct start "$id" ; rc=$? ;;
    esac
    if [[ $rc -eq 0 ]]; then
        log "$label $id start command issued successfully"
        return 0
    fi
    log "ERROR: Failed to start $label $id (exit $rc)"
    if instance_is_running "$kind" "$id"; then
        log "$label $id is running anyway, continuing"
        return 0
    fi
    return 1
}

# --- Hook entry points ------------------------------------------------------

pre_sleep() {
    log "=== PRE-SLEEP HOOK TRIGGERED ==="

    # Truncate state file — one fresh record per sleep cycle
    : > "$STATE_FILE"

    local overall_rc=0 id action

    for id in $VM_IDS; do
        action=$(get_cfg "VM_${id}_SLEEP_ACTION" "hibernate")
        case "$action" in
            hibernate)
                hibernate_vm "$id" || overall_rc=$?
                ;;
            shutdown)
                shutdown_vm "$id" || overall_rc=$?
                ;;
            keep_running)
                log "VM $id: sleep_action=keep_running"
                state_set "vm_${id}" "kept_running"
                ;;
            ignore)
                log "VM $id: sleep_action=ignore"
                state_set "vm_${id}" "ignored"
                ;;
            *)
                log "WARN: unknown VM_${id}_SLEEP_ACTION='$action' — ignoring"
                state_set "vm_${id}" "ignored"
                ;;
        esac
    done

    for id in $CONTAINER_IDS; do
        action=$(get_cfg "CONTAINER_${id}_SLEEP_ACTION" "shutdown")
        case "$action" in
            shutdown)
                shutdown_ct "$id" || overall_rc=$?
                ;;
            hibernate)
                log "WARN: hibernate not supported for LXC $id; shutting down instead"
                shutdown_ct "$id" || overall_rc=$?
                ;;
            keep_running)
                log "Container $id: sleep_action=keep_running"
                state_set "ct_${id}" "kept_running"
                ;;
            ignore)
                log "Container $id: sleep_action=ignore"
                state_set "ct_${id}" "ignored"
                ;;
            *)
                log "WARN: unknown CONTAINER_${id}_SLEEP_ACTION='$action' — ignoring"
                state_set "ct_${id}" "ignored"
                ;;
        esac
    done

    log "=== PRE-SLEEP HOOK COMPLETE (exit: $overall_rc) ==="
    # Default: return 0 so a failed instance doesn't abort systemd's sleep
    # transition (matches prior behavior). Manual callers can set
    # PRE_SLEEP_NONBLOCKING=0 to receive the aggregated result.
    if [[ "${PRE_SLEEP_NONBLOCKING:-1}" == "1" ]]; then
        return 0
    fi
    return "$overall_rc"
}

post_wake() {
    log "=== POST-WAKE HOOK TRIGGERED ==="

    # CRITICAL: clear idle monitor state and record wake time before resuming
    # anything, so the idle monitor doesn't immediately re-trigger sleep.
    local idle_state_file="$STATE_DIR/idle-monitor.state"
    local idle_wake_file="$STATE_DIR/idle-monitor.wake"
    if [[ -f "$idle_state_file" ]]; then
        log "Clearing stale idle monitor state"
        rm -f "$idle_state_file"
    fi
    date +%s > "$idle_wake_file"
    log "Wake time recorded for idle monitor"

    if [[ ! -f "$STATE_FILE" ]]; then
        log "No state file found — nothing to resume"
        log "=== POST-WAKE HOOK COMPLETE (exit: 0) ==="
        return 0
    fi

    local overall_rc=0 line key value kind id resume_flag

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        value="${line#*=}"

        case "$key" in
            vm_*)
                kind=vm
                id="${key#vm_}"
                resume_flag=$(get_cfg "VM_${id}_RESUME_ON_WAKE" "1")
                ;;
            ct_*)
                kind=ct
                id="${key#ct_}"
                resume_flag=$(get_cfg "CONTAINER_${id}_RESUME_ON_WAKE" "1")
                ;;
            *)
                log "WARN: unknown state key '$key', skipping"
                continue
                ;;
        esac

        case "$value" in
            hibernated|shutdown|was_shutdown)
                if [[ "$resume_flag" == "1" ]]; then
                    resume_instance "$kind" "$id" || overall_rc=$?
                else
                    log "$kind $id: RESUME_ON_WAKE=0, leaving stopped"
                fi
                ;;
            not_running)
                log "$kind $id was not running before sleep, leaving stopped"
                ;;
            kept_running|ignored)
                log "$kind $id was $value, no action"
                ;;
            *)
                log "WARN: unknown state value '$value' for $key"
                ;;
        esac
    done < "$STATE_FILE"

    rm -f "$STATE_FILE"

    log "=== POST-WAKE HOOK COMPLETE (exit: $overall_rc) ==="
    return $overall_rc
}

# --- Manual/status commands -------------------------------------------------

# Hibernate (or shut down per config) every configured instance without sleeping the host.
# Uses PRE_SLEEP_NONBLOCKING=0 so the caller receives the aggregated exit code.
hibernate_all() {
    PRE_SLEEP_NONBLOCKING=0 pre_sleep
}

# Resume every instance per current state file
resume_all() {
    post_wake
}

status() {
    echo "Proxmox Sleep Manager Status"
    echo "============================="
    echo "VM IDs: ${VM_IDS:-<none>}"
    echo "Container IDs: ${CONTAINER_IDS:-<none>}"
    echo ""

    local id name action resume
    for id in $VM_IDS; do
        name=$(get_cfg "VM_${id}_NAME" "vm-${id}")
        action=$(get_cfg "VM_${id}_SLEEP_ACTION" "hibernate")
        resume=$(get_cfg "VM_${id}_RESUME_ON_WAKE" "1")
        echo "VM $id ($name):"
        if vm_is_running "$id"; then
            echo "  Status:        RUNNING"
            if guest_agent_ready "$id"; then
                echo "  Guest agent:   RESPONSIVE"
            else
                echo "  Guest agent:   NOT RESPONDING"
            fi
        else
            echo "  Status:        STOPPED"
        fi
        echo "  Sleep action:  $action"
        echo "  Resume on wake: $resume"
        echo ""
    done

    for id in $CONTAINER_IDS; do
        name=$(get_cfg "CONTAINER_${id}_NAME" "ct-${id}")
        action=$(get_cfg "CONTAINER_${id}_SLEEP_ACTION" "shutdown")
        resume=$(get_cfg "CONTAINER_${id}_RESUME_ON_WAKE" "1")
        echo "Container $id ($name):"
        if ct_is_running "$id"; then
            echo "  Status:        RUNNING"
        else
            echo "  Status:        STOPPED"
        fi
        echo "  Sleep action:  $action"
        echo "  Resume on wake: $resume"
        echo ""
    done

    if [[ -f "$STATE_FILE" ]]; then
        echo "Pending state (set by last pre-sleep):"
        sed 's/^/  /' "$STATE_FILE"
    else
        echo "Pending state: none"
    fi

    echo ""
    echo "Recent Log:"
    tail -20 "$LOG_FILE" 2>/dev/null || echo "(no logs yet)"
}

# Main
case "${1:-}" in
    pre-sleep)  pre_sleep ;;
    post-wake)  post_wake ;;
    hibernate)  hibernate_all ;;
    resume)     resume_all ;;
    status)     status ;;
    *)
        echo "Usage: $0 {pre-sleep|post-wake|hibernate|resume|status}"
        echo ""
        echo "Commands:"
        echo "  pre-sleep  - Act on all configured VMs/containers before system sleep"
        echo "  post-wake  - Resume instances that were stopped by pre-sleep"
        echo "  hibernate  - Manually trigger pre-sleep actions (does NOT sleep the host)"
        echo "  resume     - Manually trigger post-wake actions"
        echo "  status     - Show current status of all configured instances"
        echo ""
        echo "Configuration:"
        echo "  Config file: /etc/proxmox-sleep.conf"
        echo "  See proxmox-sleep.conf.example for the multi-instance format."
        exit 1
        ;;
esac
