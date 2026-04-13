#!/bin/bash
#
# Proxmox Idle Monitor
# Monitors system, VM, and LXC container activity — triggers sleep when idle.
# Supports multiple VMs and containers — see proxmox-sleep.conf.example.
#

set -uo pipefail

# Load configuration file if it exists
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-sleep.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Global settings (env vars > config file > defaults)
IDLE_THRESHOLD_MINUTES="${IDLE_THRESHOLD_MINUTES:-15}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
GPU_IDLE_THRESHOLD="${GPU_IDLE_THRESHOLD:-10}"
CPU_IDLE_THRESHOLD="${CPU_IDLE_THRESHOLD:-15}"
GPU_VENDOR="${GPU_VENDOR:-auto}"
CHECK_SSH_SESSIONS="${CHECK_SSH_SESSIONS:-1}"
WAKE_GRACE_PERIOD="${WAKE_GRACE_PERIOD:-60}"
LOG_FILE="${IDLE_MONITOR_LOG:-/var/log/proxmox-idle-monitor.log}"

# Runtime state lives under /run/proxmox-sleep, a root-owned tmpfs directory.
# Using /run instead of /tmp avoids symlink-planting attacks by unprivileged
# users (everything here is written as root via `>`).
STATE_DIR="/run/proxmox-sleep"
install -d -m 0755 -o root -g root "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/idle-monitor.state"
WAKE_TIME_FILE="$STATE_DIR/idle-monitor.wake"
HOST_BLOCKING_PROCESSES="${HOST_BLOCKING_PROCESSES-}"
HOST_BLOCKING_UNITS="${HOST_BLOCKING_UNITS-apt-daily.service,apt-daily-upgrade.service}"
CHECK_SLEEP_INHIBITORS="${CHECK_SLEEP_INHIBITORS:-1}"

# Exit codes (sysexits.h)
EX_CONFIG=78

# ── Config helper ──────────────────────────────────────────────────────────────

get_cfg() {
    local var="$1" default="${2:-}"
    local val="${!var-}"
    echo "${val:-$default}"
}

# ── Legacy shim ────────────────────────────────────────────────────────────────
# If only the old VMID=... style config is present, synthesize one VM entry.

hydrate_legacy_config() {
    VM_IDS="${VM_IDS:-}"
    CONTAINER_IDS="${CONTAINER_IDS:-}"
    if [[ -z "$VM_IDS" && -z "$CONTAINER_IDS" && -n "${VMID:-}" ]]; then
        VM_IDS="$VMID"
        # GAMING_PROCESSES uses a different default expansion to tell "unset"
        # from "set to empty" — honour the existing pattern exactly.
        local legacy_gaming="${GAMING_PROCESSES-steam.exe,EpicGamesLauncher.exe,GalaxyClient.exe,Battle.net.exe,origin.exe,upc.exe}"
        printf -v "VM_${VMID}_NAME"                 '%s' "${VM_NAME:-windows-vm}"
        printf -v "VM_${VMID}_MONITOR"              '%s' "1"
        printf -v "VM_${VMID}_SLEEP_ACTION"         '%s' "hibernate"
        printf -v "VM_${VMID}_RESUME_ON_WAKE"       '%s' "1"
        printf -v "VM_${VMID}_GAMING_PROCESSES"     '%s' "$legacy_gaming"
        printf -v "VM_${VMID}_CHECK_POWER_REQUESTS" '%s' "1"
        printf -v "VM_${VMID}_CHECK_USER_IDLE"      '%s' "1"
    fi
}
hydrate_legacy_config

# ── Logging ────────────────────────────────────────────────────────────────────

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - DEBUG: $1" >> "$LOG_FILE"
    fi
}

# ── Numeric helpers ────────────────────────────────────────────────────────────

is_positive_int() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_integer()      { [[ "$1" =~ ^-?[0-9]+$ ]]; }
is_valid_metric() { is_integer "$1" && [[ "$1" != "-1" ]]; }
extract_int()          { echo "$1" | grep -oE '^-?[0-9]+' | head -1; }
extract_positive_int() { echo "$1" | grep -oE '^[0-9]+' | head -1; }

# Parse JSON "out-data" field from `qm guest exec` output.
parse_guest_output() {
    local json="$1"
    echo "$json" | tr -d '\n\r' | sed -n 's/.*"out-data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/\\r\\n//g; s/\\r//g; s/\\n//g'
}

# ── Validate configuration ─────────────────────────────────────────────────────

validate_config() {
    local errors=0

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
        echo "       Copy the example config and edit it:" >&2
        echo "       cp /usr/share/doc/proxmox-sleep/examples/proxmox-sleep.conf.example /etc/proxmox-sleep.conf" >&2
        exit $EX_CONFIG
    fi

    if [[ -z "$VM_IDS" && -z "$CONTAINER_IDS" ]]; then
        echo "ERROR: No VMs or containers configured. Set VM_IDS and/or CONTAINER_IDS." >&2
        errors=$((errors + 1))
    fi

    for id in $VM_IDS; do
        if ! qm status "$id" &>/dev/null; then
            echo "ERROR: VM $id does not exist" >&2
            errors=$((errors + 1))
        fi
    done

    for id in $CONTAINER_IDS; do
        if ! pct status "$id" &>/dev/null; then
            echo "ERROR: Container $id does not exist" >&2
            errors=$((errors + 1))
        fi
    done

    if ! [[ "$IDLE_THRESHOLD_MINUTES" =~ ^[0-9]+$ ]]; then
        echo "ERROR: IDLE_THRESHOLD_MINUTES must be a non-negative integer (current: '$IDLE_THRESHOLD_MINUTES')" >&2
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        echo "" >&2
        echo "Configuration errors found. Edit $CONFIG_FILE to fix them." >&2
        exit $EX_CONFIG
    fi
    return 0
}

# ── Instance status helpers ────────────────────────────────────────────────────

vm_is_running() {
    local id="$1" status
    status=$(qm status "$id" 2>/dev/null | awk '{print $2}')
    [[ "$status" == "running" ]]
}

ct_is_running() {
    local id="$1" status
    status=$(pct status "$id" 2>/dev/null | awk '{print $2}')
    [[ "$status" == "running" ]]
}

get_proxmox_node() {
    local node_name=""
    if [[ -d /etc/pve/nodes ]]; then
        node_name=$(ls -1 /etc/pve/nodes 2>/dev/null | head -n1)
    fi
    if [[ -z "$node_name" ]]; then
        node_name=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
    fi
    echo "$node_name"
}

# ── VM-level check functions (guest-agent / pvesh) ─────────────────────────────

# GPU usage queried *inside* the Windows VM (host nvidia-smi is blind during
# vfio-pci passthrough).
get_vm_gpu_usage() {
    local id="$1" usage="" result output

    local vendor; vendor=$(get_cfg "VM_${id}_GPU_VENDOR" "$GPU_VENDOR")

    case "$vendor" in
        nvidia)
            result=$(qm guest exec "$id" -- cmd /c "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" 2>/dev/null)
            output=$(parse_guest_output "$result")
            usage=$(extract_positive_int "$output")
            ;;
        amd)
            result=$(qm guest exec "$id" -- powershell -Command "
                try {
                    \$counter = Get-Counter '\\GPU Engine(*AMD*)\\Utilization Percentage' -ErrorAction Stop
                    [math]::Round((\$counter.CounterSamples | Measure-Object -Property CookedValue -Maximum).Maximum)
                } catch {
                    try {
                        \$counter = Get-Counter '\\GPU Engine(*engtype_3D)\\Utilization Percentage' -ErrorAction Stop
                        [math]::Round((\$counter.CounterSamples | Measure-Object -Property CookedValue -Maximum).Maximum)
                    } catch { -1 }
                }
            " 2>/dev/null)
            output=$(parse_guest_output "$result")
            usage=$(extract_int "$output")
            ;;
        auto|*)
            # NVIDIA → AMD → generic Windows perf counters
            result=$(qm guest exec "$id" -- cmd /c "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" 2>/dev/null)
            output=$(parse_guest_output "$result")
            usage=$(extract_positive_int "$output")
            if [[ -z "$usage" ]]; then
                result=$(qm guest exec "$id" -- powershell -Command "
                    try {
                        \$counter = Get-Counter '\\GPU Engine(*AMD*)\\Utilization Percentage' -ErrorAction Stop
                        [math]::Round((\$counter.CounterSamples | Measure-Object -Property CookedValue -Maximum).Maximum)
                    } catch {
                        try {
                            \$counter = Get-Counter '\\GPU Engine(*engtype_3D)\\Utilization Percentage' -ErrorAction Stop
                            [math]::Round((\$counter.CounterSamples | Measure-Object -Property CookedValue -Maximum).Maximum)
                        } catch { -1 }
                    }
                " 2>/dev/null)
                output=$(parse_guest_output "$result")
                usage=$(extract_int "$output")
            fi
            ;;
    esac

    echo "${usage:--1}"
}

get_vm_cpu_usage() {
    local id="$1" cpu json
    local node_name; node_name=$(get_proxmox_node)
    if [[ -z "$node_name" ]]; then
        debug "Failed to get Proxmox node name"
        echo "-1"
        return
    fi
    json=$(pvesh get "/nodes/$node_name/qemu/$id/status/current" --output-format json 2>/dev/null)
    cpu=$(echo "$json" | tr -d '\n\r' | sed -n 's/.*"cpu"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1)
    if [[ -n "$cpu" ]]; then
        echo "$cpu" | awk '{printf "%.0f", $1 * 100}'
    else
        echo "-1"
    fi
}

get_windows_idle_time() {
    local id="$1" result output idle_seconds

    result=$(qm guest exec "$id" -- powershell -Command '
        $idleFile = "$env:ProgramData\proxmox-idle\idle_seconds.txt"
        if (Test-Path $idleFile) {
            $content = Get-Content $idleFile -ErrorAction SilentlyContinue
            $fileTime = (Get-Item $idleFile).LastWriteTime
            $age = (Get-Date) - $fileTime
            if ($age.TotalSeconds -lt 30) {
                Write-Output $content
                return
            }
        }
        Write-Output "-1"
    ' 2>/dev/null)

    output=$(parse_guest_output "$result")
    idle_seconds=$(extract_int "$output")

    if is_valid_metric "$idle_seconds"; then
        echo "$idle_seconds"
        return
    fi

    # Fallback: screensaver / lock detection
    result=$(qm guest exec "$id" -- powershell -Command '
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ScreenStatus {
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref bool pvParam, uint fWinIni);
    const uint SPI_GETSCREENSAVERRUNNING = 0x0072;
    public static bool IsScreensaverRunning() {
        bool running = false;
        SystemParametersInfo(SPI_GETSCREENSAVERRUNNING, 0, ref running, 0);
        return running;
    }
}
"@
        $ssRunning = [ScreenStatus]::IsScreensaverRunning()
        $locked = (Get-Process -Name LogonUI -ErrorAction SilentlyContinue) -ne $null

        if ($ssRunning -or $locked) {
            Write-Output "99999"
        } else {
            Write-Output "-1"
        }
    ' 2>/dev/null)

    output=$(parse_guest_output "$result")
    idle_seconds=$(extract_int "$output")
    echo "${idle_seconds:--1}"
}

get_effective_idle_time() {
    local id="$1" win_idle seconds_since_wake

    win_idle=$(get_windows_idle_time "$id")
    seconds_since_wake=$(get_seconds_since_wake)

    if [[ "$win_idle" == "-1" ]]; then echo "-1"; return; fi
    if ! is_positive_int "$win_idle"; then debug "Invalid Windows idle time: '$win_idle'"; echo "-1"; return; fi
    if [[ "$seconds_since_wake" == "-1" ]]; then echo "$win_idle"; return; fi
    if ! is_positive_int "$seconds_since_wake"; then echo "$win_idle"; return; fi

    if [[ $win_idle -gt $seconds_since_wake ]]; then
        debug "Windows idle ($win_idle) > time since wake ($seconds_since_wake), using wake time"
        echo "$seconds_since_wake"
    else
        echo "$win_idle"
    fi
}

check_vm_gaming_processes() {
    local id="$1"
    local procs; procs=$(get_cfg "VM_${id}_GAMING_PROCESSES" "")
    if [[ -z "$procs" ]]; then
        debug "Gaming process detection disabled for VM $id (empty list)"
        return 1
    fi

    IFS=',' read -ra gaming_procs <<< "$procs"
    local result processes
    result=$(qm guest exec "$id" -- powershell -Command "Get-Process | Select-Object -ExpandProperty Name" 2>/dev/null)
    processes=$(parse_guest_output "$result")

    for proc in "${gaming_procs[@]}"; do
        proc=$(echo "$proc" | xargs)
        [[ -z "$proc" ]] && continue
        local proc_name="${proc%.exe}"
        # -F = fixed-string match: "Battle.net" etc. contain regex metachars.
        if echo "$processes" | grep -Fqi -- "$proc_name"; then
            debug "Found gaming process in VM $id: $proc"
            return 0
        fi
    done
    return 1
}

check_vm_power_requests() {
    local id="$1" result output
    result=$(qm guest exec "$id" -- powershell -Command '
        $requests = powercfg /requests
        $hasRequests = $false
        $currentCategory = ""
        $ignorePatterns = @(
            "Legacy Kernel Caller",
            "Sleep Idle State Disabled"
        )
        foreach ($line in $requests -split "`n") {
            $line = $line.Trim()
            if ($line -match "^[A-Z]+:$") {
                $currentCategory = $line
            }
            elseif ($line -and $line -ne "None." -and $currentCategory) {
                $ignore = $false
                foreach ($pattern in $ignorePatterns) {
                    if ($line -like "*$pattern*") { $ignore = $true; break }
                }
                if (-not $ignore) { $hasRequests = $true; break }
            }
        }
        if ($hasRequests) { "ACTIVE" } else { "NONE" }
    ' 2>/dev/null)
    output=$(parse_guest_output "$result")
    if [[ "$output" == "ACTIVE" ]]; then
        debug "Windows power requests active in VM $id"
        return 0
    fi
    return 1
}

# ── LXC container check functions ──────────────────────────────────────────────

get_ct_cpu_usage() {
    local id="$1" cpu json
    local node_name; node_name=$(get_proxmox_node)
    if [[ -z "$node_name" ]]; then
        echo "-1"; return
    fi
    json=$(pvesh get "/nodes/$node_name/lxc/$id/status/current" --output-format json 2>/dev/null)
    cpu=$(echo "$json" | tr -d '\n\r' | sed -n 's/.*"cpu"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1)
    if [[ -n "$cpu" ]]; then
        echo "$cpu" | awk '{printf "%.0f", $1 * 100}'
    else
        echo "-1"
    fi
}

# Host-side nvidia-smi for containers that use the GPU directly.  Degrades
# gracefully: missing binary, no device, or vfio-pci bound GPU all return -1.
get_ct_gpu_usage() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo "-1"
        return
    fi
    local output
    output=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null) || { echo "-1"; return; }
    local val; val=$(extract_positive_int "$output")
    echo "${val:--1}"
}

check_ct_gaming_processes() {
    local id="$1"
    local procs; procs=$(get_cfg "CONTAINER_${id}_GAMING_PROCESSES" "")
    if [[ -z "$procs" ]]; then
        debug "Gaming process detection disabled for container $id (empty list)"
        return 1
    fi

    IFS=',' read -ra gaming_procs <<< "$procs"

    local processes
    processes=$(pct exec "$id" -- ps -eo comm= 2>/dev/null) || processes=""

    for proc in "${gaming_procs[@]}"; do
        proc=$(echo "$proc" | xargs)
        [[ -z "$proc" ]] && continue
        if echo "$processes" | grep -Fqi -- "$proc"; then
            debug "Found gaming process in container $id: $proc"
            return 0
        fi
    done
    return 1
}

# ── Host-level check functions ─────────────────────────────────────────────────

has_active_ssh_sessions() {
    local sessions
    sessions=$(who | grep -c pts 2>/dev/null | head -1)
    sessions="${sessions:-0}"
    is_positive_int "$sessions" && [[ "$sessions" -gt 0 ]]
}

check_host_blocking_processes() {
    if [[ -z "$HOST_BLOCKING_PROCESSES" ]]; then
        debug "Host blocking process detection disabled (empty list)"
        return 1
    fi
    IFS=',' read -ra blocking_procs <<< "$HOST_BLOCKING_PROCESSES"
    for proc in "${blocking_procs[@]}"; do
        proc=$(echo "$proc" | xargs)
        [[ -z "$proc" ]] && continue
        if pgrep "$proc" > /dev/null 2>&1; then
            debug "Found host blocking process: $proc"
            return 0
        fi
    done
    return 1
}

check_host_blocking_units() {
    if [[ -z "$HOST_BLOCKING_UNITS" ]]; then
        debug "Host blocking unit detection disabled (empty list)"
        return 1
    fi
    IFS=',' read -ra blocking_units <<< "$HOST_BLOCKING_UNITS"
    for unit in "${blocking_units[@]}"; do
        unit=$(echo "$unit" | xargs)
        [[ -z "$unit" ]] && continue
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            debug "Found active blocking unit: $unit"
            return 0
        fi
    done
    return 1
}

get_active_blocking_units() {
    if [[ -z "$HOST_BLOCKING_UNITS" ]]; then echo "none"; return; fi
    local active_units=()
    IFS=',' read -ra blocking_units <<< "$HOST_BLOCKING_UNITS"
    for unit in "${blocking_units[@]}"; do
        unit=$(echo "$unit" | xargs)
        [[ -z "$unit" ]] && continue
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            active_units+=("$unit")
        fi
    done
    if [[ ${#active_units[@]} -eq 0 ]]; then echo "none"; else echo "${active_units[*]}"; fi
}

check_sleep_inhibitors() {
    if [[ "$CHECK_SLEEP_INHIBITORS" != "1" ]]; then
        debug "Sleep inhibitor detection disabled"
        return 1
    fi
    local inhibitor_list
    inhibitor_list=$(systemd-inhibit --list --no-legend 2>/dev/null)
    if [[ -z "$inhibitor_list" ]]; then
        debug "No sleep inhibitors found"
        return 1
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local what mode
        what=$(echo "$line" | awk '{print $4}')
        mode=$(echo "$line" | awk '{print $NF}')
        if [[ "$what" == *"sleep"* ]] && [[ "$mode" == "block" || "$mode" == "delay" ]]; then
            debug "Found sleep inhibitor: $line"
            return 0
        fi
    done <<< "$inhibitor_list"
    debug "No sleep-blocking inhibitors found"
    return 1
}

get_sleep_inhibitors_detail() {
    if [[ "$CHECK_SLEEP_INHIBITORS" != "1" ]]; then echo "disabled"; return; fi
    local inhibitor_list
    inhibitor_list=$(systemd-inhibit --list --no-legend 2>/dev/null)
    if [[ -z "$inhibitor_list" ]]; then echo "none"; return; fi
    local details=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local what mode who why
        what=$(echo "$line" | awk '{print $4}')
        mode=$(echo "$line" | awk '{print $NF}')
        who=$(echo "$line" | awk '{print $1}')
        why=$(echo "$line" | awk '{$1=$2=$3=$4=""; $NF=""; print}' | xargs)
        if [[ "$what" == *"sleep"* ]] && [[ "$mode" == "block" || "$mode" == "delay" ]]; then
            details+=("$who: $why ($mode)")
        fi
    done <<< "$inhibitor_list"
    if [[ ${#details[@]} -eq 0 ]]; then echo "none"; else printf '%s\n' "${details[@]}"; fi
}

# ── Power request detail (display only) ────────────────────────────────────────

get_power_requests_detail() {
    local id="$1" result output
    result=$(qm guest exec "$id" -- powershell -Command '
        $requests = powercfg /requests
        $active = @()
        $currentCategory = ""
        $ignorePatterns = @("Legacy Kernel Caller","Sleep Idle State Disabled")
        foreach ($line in $requests -split "`n") {
            $line = $line.Trim()
            if ($line -match "^[A-Z]+:$") { $currentCategory = $line -replace ":$","" }
            elseif ($line -and $line -ne "None." -and $currentCategory) {
                $ignore = $false
                foreach ($pattern in $ignorePatterns) {
                    if ($line -like "*$pattern*") { $ignore = $true; break }
                }
                if (-not $ignore) { $active += "$currentCategory : $line" }
            }
        }
        if ($active.Count -gt 0) { $active -join "; " } else { "None" }
    ' 2>/dev/null)
    output=$(parse_guest_output "$result")
    echo "${output:-None}"
}

# ── Wake / idle-state bookkeeping ──────────────────────────────────────────────

get_seconds_since_wake() {
    if [[ ! -f "$WAKE_TIME_FILE" ]]; then echo "-1"; return; fi
    local wake_time; wake_time=$(cat "$WAKE_TIME_FILE")
    # Guard against a corrupted/partial-write wake file: with `set -u`, an
    # arithmetic expansion on a non-numeric token would crash the daemon.
    if ! is_positive_int "$wake_time"; then
        log "Invalid wake timestamp in $WAKE_TIME_FILE ('$wake_time'), rewriting"
        date +%s > "$WAKE_TIME_FILE"
        echo "-1"
        return
    fi
    local current_time; current_time=$(date +%s)
    echo $((current_time - wake_time))
}

record_wake_time() {
    date +%s > "$WAKE_TIME_FILE"
    log "Wake time recorded - idle timer reset"
}

record_idle_state() {
    # IDLE_THRESHOLD_MINUTES=0 means auto-sleep is disabled. Without this
    # guard the "$idle_duration -ge 0" check below would fire immediately.
    if [[ "$IDLE_THRESHOLD_MINUTES" -le 0 ]]; then
        debug "Auto-sleep disabled (IDLE_THRESHOLD_MINUTES=0)"
        return 1
    fi

    local current_time; current_time=$(date +%s)

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "$current_time" > "$STATE_FILE"
        log "Started tracking idle time"
        return 1
    fi

    local idle_start; idle_start=$(cat "$STATE_FILE")
    if ! is_positive_int "$idle_start"; then
        log "Invalid idle start timestamp '$idle_start', resetting"
        echo "$current_time" > "$STATE_FILE"
        return 1
    fi

    local idle_seconds=$(( current_time - idle_start ))
    if (( idle_seconds < 0 )); then
        log "Negative idle duration (clock adjusted?), resetting"
        echo "$current_time" > "$STATE_FILE"
        return 1
    fi

    local idle_duration=$(( idle_seconds / 60 ))

    if [[ -f "$WAKE_TIME_FILE" ]]; then
        local wake_time; wake_time=$(cat "$WAKE_TIME_FILE")
        if is_positive_int "$wake_time" && [[ "$idle_start" -lt "$wake_time" ]]; then
            log "Stale idle state (before last wake), resetting"
            echo "$current_time" > "$STATE_FILE"
            return 1
        fi
    fi

    log "System has been idle for $idle_duration minutes"
    if [[ $idle_duration -ge $IDLE_THRESHOLD_MINUTES ]]; then
        log "Idle threshold reached ($idle_duration >= $IDLE_THRESHOLD_MINUTES minutes)"
        return 0
    fi
    return 1
}

reset_idle_state() {
    rm -f "$STATE_FILE"
    debug "Idle state reset - system is active"
}

# ── Core idle check ────────────────────────────────────────────────────────────

is_system_idle() {
    debug "Checking if system is idle..."

    # ── Host-level checks (always) ────────────────────────────────

    if [[ "$CHECK_SSH_SESSIONS" == "1" ]] && has_active_ssh_sessions; then
        debug "Active SSH sessions detected"
        return 1
    fi

    if check_host_blocking_processes; then
        debug "Host blocking processes running"
        return 1
    fi

    if check_host_blocking_units; then
        debug "Host blocking units active"
        return 1
    fi

    if check_sleep_inhibitors; then
        debug "Sleep inhibitors active"
        return 1
    fi

    # ── Per-VM checks (monitored, running) ────────────────────────

    local id monitor
    for id in $VM_IDS; do
        monitor=$(get_cfg "VM_${id}_MONITOR" "1")
        [[ "$monitor" != "1" ]] && continue

        if ! vm_is_running "$id"; then
            debug "VM $id not running - idle for this instance"
            continue
        fi

        # GPU (inside guest — host nvidia-smi is blind during vfio)
        local gpu_threshold; gpu_threshold=$(get_cfg "VM_${id}_GPU_IDLE_THRESHOLD" "$GPU_IDLE_THRESHOLD")
        local gpu_usage; gpu_usage=$(get_vm_gpu_usage "$id")
        debug "VM $id GPU usage: $gpu_usage%"
        if is_valid_metric "$gpu_usage" && [[ "$gpu_usage" -gt "$gpu_threshold" ]]; then
            debug "VM $id GPU active ($gpu_usage% > $gpu_threshold%)"
            return 1
        fi

        # CPU
        local cpu_threshold; cpu_threshold=$(get_cfg "VM_${id}_CPU_IDLE_THRESHOLD" "$CPU_IDLE_THRESHOLD")
        local cpu_usage; cpu_usage=$(get_vm_cpu_usage "$id")
        debug "VM $id CPU usage: $cpu_usage%"
        if is_valid_metric "$cpu_usage" && [[ "$cpu_usage" -gt "$cpu_threshold" ]]; then
            debug "VM $id CPU active ($cpu_usage% > $cpu_threshold%)"
            return 1
        fi

        # User idle (Windows)
        local check_user_idle; check_user_idle=$(get_cfg "VM_${id}_CHECK_USER_IDLE" "1")
        if [[ "$check_user_idle" == "1" ]]; then
            local effective_idle; effective_idle=$(get_effective_idle_time "$id")
            debug "VM $id effective idle time: ${effective_idle}s"
            local idle_threshold_seconds=$((IDLE_THRESHOLD_MINUTES * 60))
            if is_valid_metric "$effective_idle" && [[ "$effective_idle" -lt "$idle_threshold_seconds" ]]; then
                debug "VM $id user recently active (${effective_idle}s < ${idle_threshold_seconds}s)"
                return 1
            fi
        fi

        # Gaming processes
        if check_vm_gaming_processes "$id"; then
            debug "Gaming processes detected in VM $id"
            return 1
        fi

        # Power requests
        local check_power; check_power=$(get_cfg "VM_${id}_CHECK_POWER_REQUESTS" "1")
        if [[ "$check_power" == "1" ]] && check_vm_power_requests "$id"; then
            debug "Power requests active in VM $id"
            return 1
        fi
    done

    # ── Per-container checks (monitored, running) ─────────────────

    for id in $CONTAINER_IDS; do
        monitor=$(get_cfg "CONTAINER_${id}_MONITOR" "1")
        [[ "$monitor" != "1" ]] && continue

        if ! ct_is_running "$id"; then
            debug "Container $id not running - idle for this instance"
            continue
        fi

        # GPU (host-side nvidia-smi — degrades gracefully when GPU is in vfio)
        local gpu_threshold; gpu_threshold=$(get_cfg "CONTAINER_${id}_GPU_IDLE_THRESHOLD" "$GPU_IDLE_THRESHOLD")
        local gpu_usage; gpu_usage=$(get_ct_gpu_usage)
        debug "Container $id host GPU usage: $gpu_usage%"
        if is_valid_metric "$gpu_usage" && [[ "$gpu_usage" -gt "$gpu_threshold" ]]; then
            debug "Container $id GPU active ($gpu_usage% > $gpu_threshold%)"
            return 1
        fi

        # CPU
        local cpu_threshold; cpu_threshold=$(get_cfg "CONTAINER_${id}_CPU_IDLE_THRESHOLD" "$CPU_IDLE_THRESHOLD")
        local cpu_usage; cpu_usage=$(get_ct_cpu_usage "$id")
        debug "Container $id CPU usage: $cpu_usage%"
        if is_valid_metric "$cpu_usage" && [[ "$cpu_usage" -gt "$cpu_threshold" ]]; then
            debug "Container $id CPU active ($cpu_usage% > $cpu_threshold%)"
            return 1
        fi

        # Gaming processes
        if check_ct_gaming_processes "$id"; then
            debug "Gaming processes detected in container $id"
            return 1
        fi
    done

    debug "System appears idle"
    return 0
}

# ── Sleep trigger ──────────────────────────────────────────────────────────────

trigger_sleep() {
    local seconds_since_wake; seconds_since_wake=$(get_seconds_since_wake)

    if [[ "$seconds_since_wake" != "-1" ]] && is_positive_int "$seconds_since_wake" && [[ "$seconds_since_wake" -lt "$WAKE_GRACE_PERIOD" ]]; then
        log "Within wake grace period (${seconds_since_wake}s < ${WAKE_GRACE_PERIOD}s), skipping sleep"
        reset_idle_state
        return 1
    fi

    log "Triggering system sleep..."
    reset_idle_state
    systemctl suspend
}

# ── Windows idle helper install / uninstall ────────────────────────────────────

install_windows_idle_helper() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        local vm_count; vm_count=$(echo "$VM_IDS" | wc -w)
        if [[ "$vm_count" -eq 0 ]]; then
            echo "No VMs configured. Set VM_IDS in $CONFIG_FILE or pass a VMID argument:" >&2
            echo "  $0 install-helper <VMID>" >&2
            exit 1
        elif [[ "$vm_count" -eq 1 ]]; then
            id="$VM_IDS"
        else
            echo "Multiple VMs configured. Specify which VM ID:" >&2
            echo "  $0 install-helper <VMID>" >&2
            exit 1
        fi
    fi

    echo "Installing Windows idle helper in VM $id..."

    qm guest exec "$id" -- powershell -Command '
        $helperDir = "$env:ProgramData\proxmox-idle"
        if (-not (Test-Path $helperDir)) {
            New-Item -ItemType Directory -Path $helperDir -Force | Out-Null
        }
        $csCode = @"
using System;
using System.Runtime.InteropServices;
public class IdleTime {
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    public static uint GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (GetLastInputInfo(ref lii)) { return (uint)((Environment.TickCount - lii.dwTime) / 1000); }
        return 0;
    }
}
"@
        $csCode | Set-Content "$helperDir\IdleTime.cs" -Force
        Write-Output "CS file created"
    ' 2>&1

    qm guest exec "$id" -- powershell -Command '
        $helperDir = "$env:ProgramData\proxmox-idle"
        $script = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

`$csCode = Get-Content "`$env:ProgramData\proxmox-idle\IdleTime.cs" -Raw
Add-Type -TypeDefinition `$csCode

`$trayIcon = New-Object System.Windows.Forms.NotifyIcon
`$trayIcon.Icon = [System.Drawing.SystemIcons]::Information
`$trayIcon.Text = "Proxmox Idle Monitor"
`$trayIcon.Visible = `$true

`$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
`$exitItem = `$contextMenu.Items.Add("Exit")
`$exitItem.Add_Click({
    `$trayIcon.Visible = `$false
    [System.Windows.Forms.Application]::Exit()
})
`$trayIcon.ContextMenuStrip = `$contextMenu

`$timer = New-Object System.Windows.Forms.Timer
`$timer.Interval = 10000
`$timer.Add_Tick({
    try {
        `$idle = [IdleTime]::GetIdleSeconds()
        `$idle | Set-Content "`$env:ProgramData\proxmox-idle\idle_seconds.txt" -Force
        `$mins = [math]::Floor(`$idle / 60)
        `$secs = `$idle % 60
        `$trayIcon.Text = "Idle: `${mins}m `${secs}s"
    } catch {}
})
`$timer.Start()

try {
    `$idle = [IdleTime]::GetIdleSeconds()
    `$idle | Set-Content "`$env:ProgramData\proxmox-idle\idle_seconds.txt" -Force
} catch {}

[System.Windows.Forms.Application]::Run()
"@
        $script | Set-Content "$helperDir\idle_helper.ps1" -Force
        Write-Output "Script file created"
    ' 2>&1

    qm guest exec "$id" -- powershell -Command '
        $helperDir = "$env:ProgramData\proxmox-idle"
        $vbs = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & Replace(WScript.ScriptFullName, "idle_helper.vbs", "idle_helper.ps1") & """", 0, False
"@
        $vbs | Set-Content "$helperDir\idle_helper.vbs" -Force
        Write-Output "VBS wrapper created"
    ' 2>&1

    qm guest exec "$id" -- schtasks /create /tn ProxmoxIdleHelper /tr "wscript.exe \"C:\ProgramData\proxmox-idle\idle_helper.vbs\"" /sc ONLOGON /rl HIGHEST /f 2>&1

    echo "Done. The helper will start automatically on next Windows logon."
    echo "To start immediately, log out and back in, or run the scheduled task manually."
}

uninstall_windows_idle_helper() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        local vm_count; vm_count=$(echo "$VM_IDS" | wc -w)
        if [[ "$vm_count" -eq 0 ]]; then
            echo "No VMs configured. Set VM_IDS in $CONFIG_FILE or pass a VMID argument:" >&2
            echo "  $0 uninstall-helper <VMID>" >&2
            exit 1
        elif [[ "$vm_count" -eq 1 ]]; then
            id="$VM_IDS"
        else
            echo "Multiple VMs configured. Specify which VM ID:" >&2
            echo "  $0 uninstall-helper <VMID>" >&2
            exit 1
        fi
    fi

    echo "Uninstalling Windows idle helper from VM $id..."

    qm guest exec "$id" -- schtasks /delete /tn ProxmoxIdleHelper /f 2>&1

    qm guest exec "$id" -- powershell -Command '
        Get-CimInstance Win32_Process -Filter "Name=''wscript.exe''" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*idle_helper.vbs*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Write-Output "Processes killed"
    ' 2>&1

    qm guest exec "$id" -- cmd /c 'rmdir /s /q "%ProgramData%\proxmox-idle" 2>nul & echo Files removed' 2>&1

    echo "Done."
}

# ── Main monitoring loop ───────────────────────────────────────────────────────

monitor_loop() {
    log "=== Proxmox Idle Monitor Started ==="
    log "VM IDs: ${VM_IDS:-<none>}"
    log "Container IDs: ${CONTAINER_IDS:-<none>}"
    log "Idle threshold: $IDLE_THRESHOLD_MINUTES minutes"
    log "Check interval: $CHECK_INTERVAL seconds"

    while true; do
        if is_system_idle; then
            if record_idle_state; then
                trigger_sleep
                record_wake_time
                sleep 10
            fi
        else
            reset_idle_state
        fi
        sleep "$CHECK_INTERVAL"
    done
}

# ── One-time check / status (for testing) ──────────────────────────────────────

check_once() {
    echo "=== Proxmox Idle Check ==="
    echo "VM IDs: ${VM_IDS:-<none>}"
    echo "Container IDs: ${CONTAINER_IDS:-<none>}"
    echo ""

    local id monitor name

    # ── Per-VM ────────────────────────────────────────────────────
    for id in $VM_IDS; do
        monitor=$(get_cfg "VM_${id}_MONITOR" "1")
        name=$(get_cfg "VM_${id}_NAME" "vm-${id}")
        echo "VM $id ($name) [monitor=$monitor]:"
        if vm_is_running "$id"; then
            echo "  Running: YES"
            echo "  GPU Usage: $(get_vm_gpu_usage "$id")%"
            echo "  CPU Usage: $(get_vm_cpu_usage "$id")%"

            local check_user_idle; check_user_idle=$(get_cfg "VM_${id}_CHECK_USER_IDLE" "1")
            if [[ "$check_user_idle" == "1" ]]; then
                local win_idle; win_idle=$(get_windows_idle_time "$id")
                local eff_idle; eff_idle=$(get_effective_idle_time "$id")
                echo "  Windows Idle Time: ${win_idle}s"
                echo "  Effective Idle Time: ${eff_idle}s"
            fi

            local gaming_procs; gaming_procs=$(get_cfg "VM_${id}_GAMING_PROCESSES" "")
            echo -n "  Gaming Processes: "
            if [[ -z "$gaming_procs" ]]; then
                echo "DISABLED"
            elif check_vm_gaming_processes "$id"; then
                echo "DETECTED"
            else
                echo "none"
            fi

            local check_power; check_power=$(get_cfg "VM_${id}_CHECK_POWER_REQUESTS" "1")
            echo -n "  Power Requests: "
            if [[ "$check_power" != "1" ]]; then
                echo "DISABLED"
            elif check_vm_power_requests "$id"; then
                echo "ACTIVE"
                echo "    $(get_power_requests_detail "$id")"
            else
                echo "none"
            fi
        else
            echo "  Running: NO"
        fi
        echo ""
    done

    # ── Per-container ─────────────────────────────────────────────
    for id in $CONTAINER_IDS; do
        monitor=$(get_cfg "CONTAINER_${id}_MONITOR" "1")
        name=$(get_cfg "CONTAINER_${id}_NAME" "ct-${id}")
        echo "Container $id ($name) [monitor=$monitor]:"
        if ct_is_running "$id"; then
            echo "  Running: YES"
            echo "  Host GPU Usage: $(get_ct_gpu_usage)%"
            echo "  CPU Usage: $(get_ct_cpu_usage "$id")%"

            local gaming_procs; gaming_procs=$(get_cfg "CONTAINER_${id}_GAMING_PROCESSES" "")
            echo -n "  Gaming Processes: "
            if [[ -z "$gaming_procs" ]]; then
                echo "DISABLED"
            elif check_ct_gaming_processes "$id"; then
                echo "DETECTED"
            else
                echo "none"
            fi
        else
            echo "  Running: NO"
        fi
        echo ""
    done

    # ── Host-level ────────────────────────────────────────────────
    echo -n "SSH Sessions: "
    if [[ "$CHECK_SSH_SESSIONS" != "1" ]]; then echo "DISABLED"
    elif has_active_ssh_sessions; then echo "YES"
    else echo "NO"
    fi

    echo ""
    echo -n "Host Blocking Processes: "
    if [[ -z "$HOST_BLOCKING_PROCESSES" ]]; then echo "DISABLED"
    elif check_host_blocking_processes; then echo "DETECTED"
    else echo "none"
    fi

    echo ""
    echo -n "Host Blocking Units: "
    if [[ -z "$HOST_BLOCKING_UNITS" ]]; then echo "DISABLED"
    elif check_host_blocking_units; then
        echo "ACTIVE"
        echo "  $(get_active_blocking_units)"
    else echo "none"
    fi

    echo ""
    echo -n "Sleep Inhibitors: "
    if [[ "$CHECK_SLEEP_INHIBITORS" != "1" ]]; then echo "DISABLED"
    elif check_sleep_inhibitors; then
        echo "ACTIVE"
        get_sleep_inhibitors_detail | sed 's/^/  /'
    else echo "none"
    fi

    echo ""
    echo -n "Overall Idle Status: "
    if is_system_idle; then echo "IDLE"; else echo "ACTIVE"; fi
}

status() {
    check_once

    echo ""
    if is_system_idle; then
        if [[ -f "$STATE_FILE" ]]; then
            local idle_start; idle_start=$(cat "$STATE_FILE")
            local current_time; current_time=$(date +%s)
            local idle_duration=$(( (current_time - idle_start) / 60 ))
            echo "Idle Tracking: Counting down - ${idle_duration}/${IDLE_THRESHOLD_MINUTES} minutes"
            local remaining=$((IDLE_THRESHOLD_MINUTES - idle_duration))
            if (( remaining <= 0 )); then echo "Sleep in: imminent"
            else echo "Sleep in: ${remaining} minutes"
            fi
        else
            echo "Idle Tracking: Will start on next check"
        fi
    else
        echo "Idle Tracking: Paused (system is active)"
        if [[ -f "$STATE_FILE" ]]; then
            echo "  (stale state file will be cleared on next monitor cycle)"
        fi
    fi
}

# ── Main entry point ───────────────────────────────────────────────────────────

case "${1:-}" in
    start|monitor)
        validate_config
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
    sleep-now)
        echo "Triggering immediate sleep..."
        reset_idle_state
        systemctl suspend
        ;;
    install-helper)
        install_windows_idle_helper "${2:-}"
        ;;
    uninstall-helper)
        uninstall_windows_idle_helper "${2:-}"
        ;;
    *)
        echo "Usage: $0 {start|check|status|reset|sleep-now|install-helper|uninstall-helper}"
        echo ""
        echo "Commands:"
        echo "  start                    - Start the monitoring daemon"
        echo "  check                    - One-time idle check (for testing)"
        echo "  status                   - Show current status"
        echo "  reset                    - Reset idle tracking"
        echo "  sleep-now                - Immediately trigger host sleep"
        echo "  install-helper [VMID]    - Install Windows idle helper in a VM"
        echo "  uninstall-helper [VMID]  - Remove Windows idle helper from a VM"
        echo ""
        echo "Configuration:"
        echo "  Config file: /etc/proxmox-sleep.conf"
        echo "  See proxmox-sleep.conf.example for the multi-instance format."
        echo ""
        echo "Environment variables (override config file):"
        echo "  IDLE_THRESHOLD_MINUTES    - Minutes before sleep (default: 15)"
        echo "  GPU_VENDOR                - nvidia, amd, or auto (default: auto)"
        echo "  DEBUG=1                   - Enable debug logging"
        exit 1
        ;;
esac
