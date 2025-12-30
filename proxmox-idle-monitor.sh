#!/bin/bash
#
# Proxmox Idle Monitor
# Monitors system and VM activity, triggers sleep when idle
#

# Load configuration file if it exists
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-sleep.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Configuration (env vars override config file, defaults as fallback)
VMID="${PROXMOX_VMID:-${VMID:-100}}"
IDLE_THRESHOLD_MINUTES="${IDLE_THRESHOLD_MINUTES:-15}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
GPU_IDLE_THRESHOLD="${GPU_IDLE_THRESHOLD:-10}"
CPU_IDLE_THRESHOLD="${CPU_IDLE_THRESHOLD:-15}"
GPU_VENDOR="${GPU_VENDOR:-auto}"
LOG_FILE="${IDLE_MONITOR_LOG:-/var/log/proxmox-idle-monitor.log}"
STATE_FILE="/tmp/proxmox-idle-monitor.state"

# Gaming processes (from config or defaults)
# Set to empty string in config to disable gaming process detection
if [[ -z "${GAMING_PROCESSES+x}" ]]; then
    # GAMING_PROCESSES not set at all, use defaults
    GAMING_PROCESSES="steam.exe,EpicGamesLauncher.exe,GalaxyClient.exe,Battle.net.exe,origin.exe,upc.exe"
fi
# Append extra processes if defined and GAMING_PROCESSES is not empty
if [[ -n "${EXTRA_GAMING_PROCESSES:-}" ]] && [[ -n "$GAMING_PROCESSES" ]]; then
    GAMING_PROCESSES="$GAMING_PROCESSES,$EXTRA_GAMING_PROCESSES"
elif [[ -n "${EXTRA_GAMING_PROCESSES:-}" ]]; then
    GAMING_PROCESSES="$EXTRA_GAMING_PROCESSES"
fi

# Helper to parse JSON output from qm guest exec
# Extracts the value from "out-data" field
parse_guest_output() {
    local json="$1"
    # Remove newlines and extract out-data value
    echo "$json" | tr -d '\n\r' | grep -oP '"out-data"\s*:\s*"\K[^"]*' | tr -d '\r\n'
}

# Logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        log "DEBUG: $1"
    fi
}

# Check if VM is running
vm_is_running() {
    local status
    status=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
    [[ "$status" == "running" ]]
}

# Get NVIDIA GPU usage via nvidia-smi in Windows
get_nvidia_gpu_usage() {
    local result output
    result=$(qm guest exec "$VMID" -- cmd /c "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" 2>/dev/null)
    output=$(parse_guest_output "$result")
    # Extract just the number
    echo "$output" | grep -oE '^[0-9]+' | head -1
}

# Get AMD GPU usage via Windows performance counters
get_amd_gpu_usage() {
    local result output
    # AMD GPUs expose utilization via Windows performance counters
    result=$(qm guest exec "$VMID" -- powershell -Command "
        try {
            # Try AMD-specific counter first
            \$counter = Get-Counter '\\GPU Engine(*AMD*)\\Utilization Percentage' -ErrorAction Stop
            [math]::Round((\$counter.CounterSamples | Measure-Object -Property CookedValue -Maximum).Maximum)
        } catch {
            # Fallback to generic GPU engine counter
            try {
                \$counter = Get-Counter '\\GPU Engine(*engtype_3D)\\Utilization Percentage' -ErrorAction Stop
                [math]::Round((\$counter.CounterSamples | Measure-Object -Property CookedValue -Maximum).Maximum)
            } catch { -1 }
        }
    " 2>/dev/null)
    output=$(parse_guest_output "$result")
    echo "$output" | grep -oE '^-?[0-9]+' | head -1
}

# Get Windows performance counter GPU usage (generic fallback)
get_perfcounter_gpu_usage() {
    local result output
    result=$(qm guest exec "$VMID" -- powershell -Command "
        try {
            \$gpu = Get-Counter '\\GPU Engine(*engtype_3D)\\Utilization Percentage' -ErrorAction Stop
            [math]::Round((\$gpu.CounterSamples | Measure-Object -Property CookedValue -Maximum).Maximum)
        } catch { -1 }
    " 2>/dev/null)
    output=$(parse_guest_output "$result")
    echo "$output" | grep -oE '^-?[0-9]+' | head -1
}

# Get GPU utilization from inside Windows VM via guest agent
get_gpu_usage() {
    if ! vm_is_running; then
        echo "-1"
        return
    fi

    local usage=""

    case "$GPU_VENDOR" in
        nvidia)
            usage=$(get_nvidia_gpu_usage)
            ;;
        amd)
            usage=$(get_amd_gpu_usage)
            ;;
        auto|*)
            # Try NVIDIA first (most common for gaming passthrough)
            usage=$(get_nvidia_gpu_usage)
            if [[ -z "$usage" ]]; then
                # Try AMD
                usage=$(get_amd_gpu_usage)
            fi
            if [[ -z "$usage" ]]; then
                # Fall back to generic Windows performance counters
                usage=$(get_perfcounter_gpu_usage)
            fi
            ;;
    esac

    echo "${usage:--1}"
}

# Get VM CPU usage from Proxmox
get_vm_cpu_usage() {
    # Use pvesh to get VM status which includes CPU
    local cpu json
    json=$(pvesh get /nodes/$(hostname)/qemu/$VMID/status/current --output-format json 2>/dev/null)
    # Handle multi-line JSON - remove newlines and parse
    cpu=$(echo "$json" | tr -d '\n\r' | grep -oP '"cpu"\s*:\s*\K[0-9.]+' | head -1)
    if [[ -n "$cpu" ]]; then
        # Convert from 0-1 to percentage
        echo "$cpu" | awk '{printf "%.0f", $1 * 100}'
    else
        echo "-1"
    fi
}

# Check if there are active SSH sessions to the host
has_active_ssh_sessions() {
    local sessions
    sessions=$(who | grep -c pts 2>/dev/null || echo "0")
    [[ "$sessions" -gt 0 ]]
}

# Check Windows idle time via guest agent (requires script in Windows)
get_windows_idle_time() {
    # Try to get Windows idle time using PowerShell via guest agent
    local result output
    result=$(qm guest exec "$VMID" -- powershell -Command "
        Add-Type @'
        using System;
        using System.Runtime.InteropServices;
        public class IdleTime {
            [DllImport(\"user32.dll\")]
            static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

            [StructLayout(LayoutKind.Sequential)]
            struct LASTINPUTINFO {
                public uint cbSize;
                public uint dwTime;
            }

            public static uint GetIdleSeconds() {
                LASTINPUTINFO lii = new LASTINPUTINFO();
                lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
                if (GetLastInputInfo(ref lii)) {
                    return (uint)((Environment.TickCount - lii.dwTime) / 1000);
                }
                return 0;
            }
        }
'@
        [IdleTime]::GetIdleSeconds()
    " 2>/dev/null)

    # Parse the output
    output=$(parse_guest_output "$result")
    local idle_seconds
    idle_seconds=$(echo "$output" | grep -oE '^[0-9]+' | head -1)
    echo "${idle_seconds:--1}"
}

# Check if specific gaming processes are running
check_gaming_processes() {
    # Skip if no gaming processes configured
    if [[ -z "$GAMING_PROCESSES" ]]; then
        debug "Gaming process detection disabled (empty list)"
        return 1  # No gaming processes to check = not detected
    fi

    # Convert comma-separated list to array
    IFS=',' read -ra gaming_procs <<< "$GAMING_PROCESSES"

    # Check via guest agent
    local result processes
    result=$(qm guest exec "$VMID" -- powershell -Command "Get-Process | Select-Object -ExpandProperty Name" 2>/dev/null)
    processes=$(parse_guest_output "$result")

    for proc in "${gaming_procs[@]}"; do
        # Trim whitespace and remove .exe extension for matching
        proc=$(echo "$proc" | xargs)
        [[ -z "$proc" ]] && continue
        local proc_name="${proc%.exe}"
        if echo "$processes" | grep -qi "$proc_name"; then
            debug "Found gaming process: $proc"
            return 0  # Gaming process found
        fi
    done

    return 1  # No gaming processes found
}

# Check if system should be considered idle
is_system_idle() {
    debug "Checking if system is idle..."

    # Check 1: Is VM running at all?
    if ! vm_is_running; then
        debug "VM not running - considering idle"
        return 0  # VM not running = idle
    fi

    # Check 2: GPU usage (if available)
    local gpu_usage
    gpu_usage=$(get_gpu_usage)
    debug "GPU usage: $gpu_usage%"
    if [[ "$gpu_usage" != "-1" ]] && [[ "$gpu_usage" -gt "$GPU_IDLE_THRESHOLD" ]]; then
        debug "GPU active ($gpu_usage% > $GPU_IDLE_THRESHOLD%)"
        return 1  # GPU is active
    fi

    # Check 3: VM CPU usage
    local cpu_usage
    cpu_usage=$(get_vm_cpu_usage)
    debug "VM CPU usage: $cpu_usage%"
    if [[ "$cpu_usage" != "-1" ]] && [[ "$cpu_usage" -gt "$CPU_IDLE_THRESHOLD" ]]; then
        debug "VM CPU active ($cpu_usage% > $CPU_IDLE_THRESHOLD%)"
        return 1  # CPU is active
    fi

    # Check 4: SSH sessions to host
    if has_active_ssh_sessions; then
        debug "Active SSH sessions detected"
        return 1  # Someone is connected
    fi

    # Check 5: Windows idle time (most reliable but requires guest agent)
    local win_idle
    win_idle=$(get_windows_idle_time)
    debug "Windows idle time: ${win_idle}s"
    local idle_threshold_seconds=$((IDLE_THRESHOLD_MINUTES * 60))
    if [[ "$win_idle" != "-1" ]] && [[ "$win_idle" -lt "$idle_threshold_seconds" ]]; then
        debug "Windows user recently active (${win_idle}s < ${idle_threshold_seconds}s)"
        return 1  # User recently active in Windows
    fi

    # Check 6: Gaming processes (optional extra check)
    if check_gaming_processes; then
        debug "Gaming processes detected"
        return 1  # Gaming in progress
    fi

    debug "System appears idle"
    return 0  # System is idle
}

# Record idle state
record_idle_state() {
    local current_time
    current_time=$(date +%s)

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "$current_time" > "$STATE_FILE"
        log "Started tracking idle time"
        return
    fi

    local idle_start
    idle_start=$(cat "$STATE_FILE")
    local idle_duration=$(( (current_time - idle_start) / 60 ))

    log "System has been idle for $idle_duration minutes"

    if [[ $idle_duration -ge $IDLE_THRESHOLD_MINUTES ]]; then
        log "Idle threshold reached ($idle_duration >= $IDLE_THRESHOLD_MINUTES minutes)"
        return 0  # Should sleep
    fi

    return 1  # Not yet time to sleep
}

# Reset idle tracking
reset_idle_state() {
    rm -f "$STATE_FILE"
    debug "Idle state reset - system is active"
}

# Trigger system sleep
trigger_sleep() {
    log "Triggering system sleep..."
    reset_idle_state

    # systemctl suspend will trigger our sleep hooks
    systemctl suspend
}

# Main monitoring loop
monitor_loop() {
    log "=== Proxmox Idle Monitor Started ==="
    log "VM ID: $VMID"
    log "Idle threshold: $IDLE_THRESHOLD_MINUTES minutes"
    log "Check interval: $CHECK_INTERVAL seconds"

    while true; do
        if is_system_idle; then
            if record_idle_state; then
                trigger_sleep
                # After wake, reset and continue
                sleep 60  # Give system time to stabilize after wake
            fi
        else
            reset_idle_state
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# One-time check (for testing)
check_once() {
    echo "=== Proxmox Idle Check ==="
    echo "VM ID: $VMID"
    echo ""

    echo "VM Status:"
    if vm_is_running; then
        echo "  Running: YES"

        echo ""
        echo "GPU Usage: $(get_gpu_usage)%"
        echo "VM CPU Usage: $(get_vm_cpu_usage)%"

        echo ""
        echo "Windows Idle Time: $(get_windows_idle_time) seconds"

        echo ""
        echo -n "Gaming Processes: "
        if [[ -z "$GAMING_PROCESSES" ]]; then
            echo "DISABLED"
        elif check_gaming_processes; then
            echo "DETECTED"
        else
            echo "none"
        fi
    else
        echo "  Running: NO"
    fi

    echo ""
    echo -n "SSH Sessions: "
    if has_active_ssh_sessions; then
        echo "YES"
    else
        echo "NO"
    fi

    echo ""
    echo -n "Overall Idle Status: "
    if is_system_idle; then
        echo "IDLE"
    else
        echo "ACTIVE"
    fi
}

# Show status
status() {
    check_once

    echo ""
    if [[ -f "$STATE_FILE" ]]; then
        local idle_start
        idle_start=$(cat "$STATE_FILE")
        local current_time
        current_time=$(date +%s)
        local idle_duration=$(( (current_time - idle_start) / 60 ))
        echo "Idle Tracking: Active for $idle_duration minutes"
        echo "Sleep in: $((IDLE_THRESHOLD_MINUTES - idle_duration)) minutes"
    else
        echo "Idle Tracking: Not idle"
    fi
}

# Main
case "${1:-}" in
    start|monitor)
        monitor_loop
        ;;
    check)
        check_once
        ;;
    status)
        status
        ;;
    reset)
        reset_idle_state
        echo "Idle state reset"
        ;;
    *)
        echo "Usage: $0 {start|check|status|reset}"
        echo ""
        echo "Commands:"
        echo "  start   - Start the monitoring daemon"
        echo "  check   - One-time idle check (for testing)"
        echo "  status  - Show current status"
        echo "  reset   - Reset idle tracking"
        echo ""
        echo "Configuration:"
        echo "  Config file: /etc/proxmox-sleep.conf"
        echo "  See proxmox-sleep.conf.example for all options"
        echo ""
        echo "Environment variables (override config file):"
        echo "  PROXMOX_VMID              - VM ID (default: 100)"
        echo "  IDLE_THRESHOLD_MINUTES    - Minutes before sleep (default: 15)"
        echo "  GPU_VENDOR                - nvidia, amd, or auto (default: auto)"
        echo "  GAMING_PROCESSES          - Comma-separated process list"
        echo "  DEBUG=1                   - Enable debug logging"
        exit 1
        ;;
esac
