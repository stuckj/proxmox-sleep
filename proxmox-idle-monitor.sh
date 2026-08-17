#!/bin/bash
#
# Proxmox Idle Monitor
# Monitors system, VM, and LXC container activity — triggers sleep when idle.
# Supports multiple VMs and containers — see proxmox-sleep.conf.example.
#

set -uo pipefail

# Load configuration file if it exists
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-sleep.conf}"

# Sourcing assigns, so any setting the config file names would otherwise
# overwrite the one inherited from the environment — the reverse of the
# documented precedence, and enough to make `DEBUG=1 ... check` silently do
# nothing against the shipped example, which sets DEBUG=0. Snapshot what the
# environment supplied and reapply it afterwards. The systemd units run with a
# clean environment, so this only affects interactive invocations.
declare -A _ENV_SNAPSHOT=()
while IFS= read -r _name; do
    _ENV_SNAPSHOT["$_name"]="${!_name}"
done < <(compgen -e)

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

for _name in "${!_ENV_SNAPSHOT[@]}"; do
    printf -v "$_name" '%s' "${_ENV_SNAPSHOT[$_name]}"
done
unset _name _ENV_SNAPSHOT

# Global settings (env vars > config file > defaults)
IDLE_THRESHOLD_MINUTES="${IDLE_THRESHOLD_MINUTES:-15}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
DEFAULT_GPU_IDLE_THRESHOLD=10
DEFAULT_CPU_IDLE_THRESHOLD=15
GPU_IDLE_THRESHOLD="${GPU_IDLE_THRESHOLD:-$DEFAULT_GPU_IDLE_THRESHOLD}"
CPU_IDLE_THRESHOLD="${CPU_IDLE_THRESHOLD:-$DEFAULT_CPU_IDLE_THRESHOLD}"
GPU_VENDOR="${GPU_VENDOR:-auto}"
CHECK_SSH_SESSIONS="${CHECK_SSH_SESSIONS:-1}"
DEBUG="${DEBUG:-0}"
WAKE_GRACE_PERIOD="${WAKE_GRACE_PERIOD:-60}"
LOG_FILE="${IDLE_MONITOR_LOG:-/var/log/proxmox-idle-monitor.log}"

# Runtime state lives under /run/proxmox-sleep, a root-owned tmpfs directory.
# Using /run instead of /tmp avoids symlink-planting attacks by unprivileged
# users (everything here is written as root via `>`).
# PROXMOX_SLEEP_STATE_DIR redirects this for the offline test harness only.
# It is not a supported config knob: the systemd units run with a clean
# environment, so nothing but a root-run test can set it.
STATE_DIR="${PROXMOX_SLEEP_STATE_DIR:-/run/proxmox-sleep}"
# Note: EX_CONFIG=78 is defined below; use the literal here since it's early.
if ! install -d -m 0755 -o root -g root "$STATE_DIR"; then
    echo "ERROR: Failed to create runtime state directory: $STATE_DIR" >&2
    echo "       This must run as root — try: sudo $0 $*" >&2
    exit 78
fi
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
    # printf, not echo: a value starting with -n/-e would be parsed as an option.
    printf '%s\n' "${val:-$default}"
}

# ── Legacy shim ────────────────────────────────────────────────────────────────
# If only the old VMID=... style config is present, synthesize one VM entry.

# Synthesize a legacy default only where the user has said nothing. An explicit
# VM_<id>_* in a half-migrated config must win over the shim.
set_if_unset() {
    local name="$1" value="$2"
    [[ -n "${!name+x}" ]] && return 0
    printf -v "$name" '%s' "$value"
}

# Drop repeated IDs from the named variable, preserving order. Walking one
# twice makes the second pass overwrite the state the first recorded, leaving
# the instance stopped on wake; sleep-now suspends without running
# validate_config, so the lists must be safe here and not only at daemon start.
# What was dropped is recorded so validate_config can still name the typo.
DUPLICATE_IDS=""
dedupe_ids() {
    local var="$1" id out=""
    # shellcheck disable=SC2086  # the ID list is space-separated on purpose
    for id in ${!var}; do
        if [[ " $out " == *" $id "* ]]; then
            DUPLICATE_IDS+="${DUPLICATE_IDS:+ }$id"
            continue
        fi
        out+="${out:+ }$id"
    done
    printf -v "$var" '%s' "$out"
}

hydrate_legacy_config() {
    VM_IDS="${VM_IDS:-}"
    CONTAINER_IDS="${CONTAINER_IDS:-}"
    # Keyed on VM_IDS alone: a legacy install that adds CONTAINER_IDS must keep
    # its VMID= entry, not lose the VM because a container appeared.
    if [[ -z "$VM_IDS" && -n "${VMID:-}" ]]; then
        VM_IDS="$VMID"
        # GAMING_PROCESSES uses a different default expansion to tell "unset"
        # from "set to empty" — honour the existing pattern exactly.
        local legacy_gaming="${GAMING_PROCESSES-steam.exe,EpicGamesLauncher.exe,GalaxyClient.exe,Battle.net.exe,origin.exe,upc.exe}"
        set_if_unset "VM_${VMID}_NAME"                 "${VM_NAME:-windows-vm}"
        set_if_unset "VM_${VMID}_MONITOR"              "1"
        set_if_unset "VM_${VMID}_SLEEP_ACTION"         "hibernate"
        set_if_unset "VM_${VMID}_RESUME_ON_WAKE"       "1"
        set_if_unset "VM_${VMID}_GAMING_PROCESSES"     "$legacy_gaming"
        set_if_unset "VM_${VMID}_CHECK_POWER_REQUESTS" "1"
        set_if_unset "VM_${VMID}_CHECK_USER_IDLE"      "1"
    fi
    dedupe_ids VM_IDS
    dedupe_ids CONTAINER_IDS
}
hydrate_legacy_config

# ── Logging ────────────────────────────────────────────────────────────────────

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

debug() {
    if is_enabled "$DEBUG"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - DEBUG: $1" >> "$LOG_FILE"
    fi
}

# ── Numeric helpers ────────────────────────────────────────────────────────────

# A per-instance flag counts as off only when explicitly 0. Erring toward "on"
# means a typo monitors and resumes an instance rather than silently skipping it
# and leaving it stopped; validate_config rejects the typo at startup anyway.
is_enabled() { [[ "$1" != "0" ]]; }

# Leading zeros are rejected: `[[ x -gt 08 ]]` evaluates its operands as
# arithmetic, where a leading zero means octal, so 08/09 are invalid and the
# test errors out to false. Accepting them here would let validate_config pass a
# value that silently disables the comparison it guards.
is_positive_int() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }
is_integer()      { [[ "$1" =~ ^-?[0-9]+$ ]]; }
is_valid_metric() { is_integer "$1" && [[ "$1" != "-1" ]]; }
extract_int()          { echo "$1" | grep -oE '^-?[0-9]+' | head -1; }
extract_positive_int() { echo "$1" | grep -oE '^[0-9]+' | head -1; }

# check/status never call validate_config, so a threshold the daemon would have
# refused to start on must not abort them: `-gt` evaluates its operand
# arithmetically and a non-numeric word is fatal under `set -u`.
get_threshold() {
    local var="$1" fallback="$2" builtin_default="$3" value
    value=$(get_cfg "$var" "$fallback")
    is_positive_int "$value" || value="$builtin_default"
    printf '%s\n' "$value"
}

# Parse JSON "out-data" field from `qm guest exec` output.
# The raw JSON spans multiple shell lines, so real \n/\r in the wrapper must be
# collapsed before extracting `out-data`.  The *value* of out-data, however, is
# escaped (\\r\\n / \\n), and must be converted back to real newlines so that
# callers can distinguish separate lines (e.g., a process list) when matching.
parse_guest_output() {
    local json="$1" out
    out=$(printf '%s' "$json" | tr -d '\n\r' | sed -n 's/.*"out-data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    out="${out//\\r\\n/$'\n'}"
    out="${out//\\n/$'\n'}"
    out="${out//\\r/}"
    printf '%s' "$out"
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

    # These reach bare -gt/-lt tests, which evaluate their operand
    # arithmetically: a non-numeric word aborts the daemon under `set -u`, and
    # systemd restarts it straight into the same failure.
    local numeric nval
    for numeric in CPU_IDLE_THRESHOLD GPU_IDLE_THRESHOLD WAKE_GRACE_PERIOD; do
        nval="${!numeric}"
        if ! is_positive_int "$nval"; then
            echo "ERROR: $numeric must be a non-negative integer (current: '$nval')" >&2
            errors=$((errors + 1))
        fi
    done

    # Zero is meaningless for a poll interval: monitor_loop's `sleep 0` returns
    # instantly and the daemon spins, forking qm/pct/pvesh continuously.
    if ! is_positive_int "$CHECK_INTERVAL" || [[ "$CHECK_INTERVAL" -lt 1 ]]; then
        echo "ERROR: CHECK_INTERVAL must be a positive integer (current: '$CHECK_INTERVAL')" >&2
        errors=$((errors + 1))
    fi

    # These belong to proxmox-sleep-manager.sh, which validates nothing and has
    # no defaults here — but it reads the same file, and a non-numeric
    # HIBERNATE_TIMEOUT makes its poll loop run zero times and send `qm shutdown`
    # to a guest that is still writing hiberfil.sys. Unset is fine: the manager
    # supplies its own numeric default.
    for numeric in HIBERNATE_TIMEOUT SHUTDOWN_TIMEOUT; do
        nval="${!numeric-}"
        [[ -z "$nval" ]] && continue
        # Zero would make hibernate_vm's poll loop run no iterations at all and
        # fall straight through to `qm shutdown` on a guest mid-hibernate.
        if ! is_positive_int "$nval" || [[ "$nval" -lt 1 ]]; then
            echo "ERROR: $numeric must be a positive integer (current: '$nval')" >&2
            errors=$((errors + 1))
        fi
    done

    nval="${WAKE_DELAY-}"
    if [[ -n "$nval" ]] && ! is_positive_int "$nval"; then
        echo "ERROR: WAKE_DELAY must be a non-negative integer (current: '$nval')" >&2
        errors=$((errors + 1))
    fi

    # Host-level checks follow the same rule as the per-instance flags: off only
    # when explicitly 0, and anything else is a typo that would silently drop a
    # guard against an active user.
    local hostflag hval
    for hostflag in CHECK_SSH_SESSIONS CHECK_SLEEP_INHIBITORS DEBUG; do
        hval="${!hostflag}"
        if [[ "$hval" != "0" && "$hval" != "1" ]]; then
            echo "ERROR: $hostflag='$hval' must be 0 or 1" >&2
            errors=$((errors + 1))
        fi
    done

    # hydrate_legacy_config already dropped these so no code path acts on an ID
    # twice, but the typo is still worth surfacing rather than silently fixing.
    if [[ -n "$DUPLICATE_IDS" ]]; then
        echo "ERROR: duplicate instance IDs in VM_IDS/CONTAINER_IDS: $DUPLICATE_IDS" >&2
        errors=$((errors + 1))
    fi

    # An unrecognised action falls through to a fallback, and an unrecognised
    # flag to its safe branch — both mean the config does not do what it says.
    # Refuse to start rather than run a misread config for weeks.
    local kind_action
    for id in $VM_IDS; do
        kind_action=$(get_cfg "VM_${id}_SLEEP_ACTION" "hibernate")
        case "$kind_action" in
            hibernate|shutdown|keep_running|ignore) ;;
            *)
                echo "ERROR: VM_${id}_SLEEP_ACTION='$kind_action' is not one of: hibernate, shutdown, keep_running, ignore" >&2
                errors=$((errors + 1))
                ;;
        esac
        local flag
        for flag in MONITOR RESUME_ON_WAKE CHECK_USER_IDLE CHECK_POWER_REQUESTS; do
            local val; val=$(get_cfg "VM_${id}_${flag}" "1")
            if [[ "$val" != "0" && "$val" != "1" ]]; then
                echo "ERROR: VM_${id}_${flag}='$val' must be 0 or 1" >&2
                errors=$((errors + 1))
            fi
        done
        local thr tval
        for thr in CPU_IDLE_THRESHOLD GPU_IDLE_THRESHOLD; do
            tval=$(get_cfg "VM_${id}_${thr}" "0")
            if ! is_positive_int "$tval"; then
                echo "ERROR: VM_${id}_${thr}='$tval' must be a non-negative integer" >&2
                errors=$((errors + 1))
            fi
        done
    done

    for id in $CONTAINER_IDS; do
        kind_action=$(get_cfg "CONTAINER_${id}_SLEEP_ACTION" "shutdown")
        case "$kind_action" in
            hibernate|shutdown|keep_running|ignore) ;;
            *)
                echo "ERROR: CONTAINER_${id}_SLEEP_ACTION='$kind_action' is not one of: shutdown, keep_running, ignore (hibernate falls back to shutdown)" >&2
                errors=$((errors + 1))
                ;;
        esac
        for flag in MONITOR RESUME_ON_WAKE; do
            local ct_val; ct_val=$(get_cfg "CONTAINER_${id}_${flag}" "1")
            if [[ "$ct_val" != "0" && "$ct_val" != "1" ]]; then
                echo "ERROR: CONTAINER_${id}_${flag}='$ct_val' must be 0 or 1" >&2
                errors=$((errors + 1))
            fi
        done
        for thr in CPU_IDLE_THRESHOLD GPU_IDLE_THRESHOLD; do
            tval=$(get_cfg "CONTAINER_${id}_${thr}" "0")
            if ! is_positive_int "$tval"; then
                echo "ERROR: CONTAINER_${id}_${thr}='$tval' must be a non-negative integer" >&2
                errors=$((errors + 1))
            fi
        done
    done

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
    # /etc/pve/nodes lists every node in the cluster, so picking the first
    # entry returns whichever sorts first — not necessarily this host. The
    # local hostname is the node name on Proxmox; the directory only confirms it.
    local node_name=""
    node_name=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
    if [[ -n "$node_name" && -d "/etc/pve/nodes/$node_name" ]]; then
        printf '%s\n' "$node_name"
        return
    fi
    if [[ -d /etc/pve/nodes ]]; then
        local first; first=$(ls -1 /etc/pve/nodes 2>/dev/null | head -n1)
        if [[ -n "$first" ]]; then
            printf '%s\n' "$first"
            return
        fi
    fi
    printf '%s\n' "$node_name"
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
        # Lowercase first so we strip the .exe suffix case-insensitively —
        # users sometimes write "Steam.EXE" / "STEAM.EXE" in config.
        local proc_name="${proc,,}"
        proc_name="${proc_name%.exe}"
        # -Fxqi: fixed-string, whole-line, quiet, case-insensitive.
        # Exact match (not substring) so "steam" does not also catch
        # "steamwebhelper". Users who want to block sleep on helpers too
        # must list them explicitly in GAMING_PROCESSES.
        if echo "$processes" | grep -Fxqi -- "$proc_name"; then
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
# On multi-GPU hosts, nvidia-smi returns one row per GPU; take the max so
# activity on any GPU blocks sleep.
get_ct_gpu_usage() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo "-1"
        return
    fi
    local output max_val
    output=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null) || { echo "-1"; return; }
    max_val=$(echo "$output" | awk '
        BEGIN { max = -1 }
        /^[[:space:]]*[0-9]+[[:space:]]*$/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if ($0 + 0 > max) { max = $0 + 0 }
        }
        END { print max }
    ')
    echo "${max_val:--1}"
}

check_ct_gaming_processes() {
    local id="$1"
    local procs; procs=$(get_cfg "CONTAINER_${id}_GAMING_PROCESSES" "")
    if [[ -z "$procs" ]]; then
        debug "Gaming process detection disabled for container $id (empty list)"
        return 1
    fi

    IFS=',' read -ra gaming_procs <<< "$procs"

    # Use `ps -eo args=` (full command line) and extract argv[0]'s basename
    # per line. The `comm` column is truncated to 15 chars by the kernel,
    # which would silently miss long process names like "steamwebhelper"
    # (14 — fits, but any longer name would be cut off).
    local processes
    processes=$(pct exec "$id" -- sh -c 'ps -eo args= 2>/dev/null | awk "{print \$1}" | while IFS= read -r p; do basename "$p"; done' 2>/dev/null) || processes=""

    for proc in "${gaming_procs[@]}"; do
        proc=$(echo "$proc" | xargs)
        [[ -z "$proc" ]] && continue
        # -Fxqi: fixed-string, whole-line, quiet, case-insensitive.
        # Exact match so "steam" does not also catch "steamwebhelper".
        if echo "$processes" | grep -Fxqi -- "$proc"; then
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
        # -f matches the full command line. Without it pgrep compares against
        # comm, which the kernel truncates to 15 characters, and procps refuses
        # a longer pattern outright — so the shipped "unattended-upgrade"
        # default could never match. Same constraint the container path handles.
        if pgrep -f -- "$proc" > /dev/null 2>&1; then
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

# Split one `systemd-inhibit --list --no-legend` row into WHO/WHAT/WHY/MODE.
# The columns are WHO UID USER PID COMM WHAT WHY MODE, but WHO and WHY both
# contain spaces in practice ("Unattended Upgrades Shutdown 0 root 344 ..."),
# so no fixed field index finds WHAT. UID and PID are the dependable landmark:
# both numeric and two fields apart, putting WHAT four past UID and MODE last.
parse_inhibitor_line() {
    awk '{
        for (i = 1; i + 4 <= NF; i++) {
            if ($i ~ /^[0-9]+$/ && $(i + 2) ~ /^[0-9]+$/) {
                who = ""
                for (j = 1; j < i; j++) who = who (j > 1 ? " " : "") $j
                why = ""
                for (j = i + 5; j < NF; j++) why = why (j > i + 5 ? " " : "") $j
                printf "%s\t%s\t%s\t%s\n", who, $(i + 4), why, $NF
                exit
            }
        }
    }'
}

# WHAT is a colon-separated list, so a sleep inhibitor may read "sleep" or
# "sleep:shutdown". block-weak is deliberately not treated as blocking: it
# exists to be overridden by a privileged caller, which is what this is.
inhibits_sleep() {
    local what="$1" mode="$2"
    [[ "$what" == *"sleep"* ]] && [[ "$mode" == "block" || "$mode" == "delay" ]]
}

check_sleep_inhibitors() {
    if ! is_enabled "$CHECK_SLEEP_INHIBITORS"; then
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
        local who what why mode
        IFS=$'\t' read -r who what why mode < <(printf '%s\n' "$line" | parse_inhibitor_line)
        if inhibits_sleep "$what" "$mode"; then
            debug "Found sleep inhibitor: $line"
            return 0
        fi
    done <<< "$inhibitor_list"
    debug "No sleep-blocking inhibitors found"
    return 1
}

get_sleep_inhibitors_detail() {
    if ! is_enabled "$CHECK_SLEEP_INHIBITORS"; then echo "disabled"; return; fi
    local inhibitor_list
    inhibitor_list=$(systemd-inhibit --list --no-legend 2>/dev/null)
    if [[ -z "$inhibitor_list" ]]; then echo "none"; return; fi
    local details=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local who what why mode
        IFS=$'\t' read -r who what why mode < <(printf '%s\n' "$line" | parse_inhibitor_line)
        if inhibits_sleep "$what" "$mode"; then
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
        # This function's stdout IS its return value (callers use $(...)), and
        # log() echoes through tee, so the message must go to stderr or it
        # would be concatenated onto the "-1" the caller parses.
        log "Invalid wake timestamp in $WAKE_TIME_FILE ('$wake_time'), rewriting" >&2
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

    if is_enabled "$CHECK_SSH_SESSIONS" && has_active_ssh_sessions; then
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
        is_enabled "$monitor" || continue

        if ! vm_is_running "$id"; then
            debug "VM $id not running - idle for this instance"
            continue
        fi

        # GPU (inside guest — host nvidia-smi is blind during vfio)
        local gpu_threshold; gpu_threshold=$(get_threshold "VM_${id}_GPU_IDLE_THRESHOLD" "$GPU_IDLE_THRESHOLD" "$DEFAULT_GPU_IDLE_THRESHOLD")
        local gpu_usage; gpu_usage=$(get_vm_gpu_usage "$id")
        debug "VM $id GPU usage: $gpu_usage%"
        if is_valid_metric "$gpu_usage" && [[ "$gpu_usage" -gt "$gpu_threshold" ]]; then
            debug "VM $id GPU active ($gpu_usage% > $gpu_threshold%)"
            return 1
        fi

        # CPU
        local cpu_threshold; cpu_threshold=$(get_threshold "VM_${id}_CPU_IDLE_THRESHOLD" "$CPU_IDLE_THRESHOLD" "$DEFAULT_CPU_IDLE_THRESHOLD")
        local cpu_usage; cpu_usage=$(get_vm_cpu_usage "$id")
        debug "VM $id CPU usage: $cpu_usage%"
        if is_valid_metric "$cpu_usage" && [[ "$cpu_usage" -gt "$cpu_threshold" ]]; then
            debug "VM $id CPU active ($cpu_usage% > $cpu_threshold%)"
            return 1
        fi

        # User idle (Windows). Use an instantaneous "recently active" signal
        # (CHECK_INTERVAL seconds) rather than the full IDLE_THRESHOLD_MINUTES
        # window — record_idle_state is the single source of truth for the
        # configured idle duration. Previously both places gated on the full
        # threshold, which effectively doubled the real post-wake wait before
        # the next sleep fired.
        #
        # Wake safety: get_effective_idle_time clamps to seconds_since_wake,
        # so the first CHECK_INTERVAL seconds after wake always read as
        # "recently active" regardless of what Windows reports for win_idle.
        # Combined with WAKE_GRACE_PERIOD in trigger_sleep, this still
        # prevents immediate re-sleep after wake.
        local check_user_idle; check_user_idle=$(get_cfg "VM_${id}_CHECK_USER_IDLE" "1")
        if is_enabled "$check_user_idle"; then
            local effective_idle; effective_idle=$(get_effective_idle_time "$id")
            debug "VM $id effective idle time: ${effective_idle}s"
            local interval; interval=$(get_threshold CHECK_INTERVAL "$CHECK_INTERVAL" 60)
            if is_valid_metric "$effective_idle" && [[ "$effective_idle" -lt "$interval" ]]; then
                debug "VM $id user recently active (${effective_idle}s < ${CHECK_INTERVAL}s)"
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
        if is_enabled "$check_power" && check_vm_power_requests "$id"; then
            debug "Power requests active in VM $id"
            return 1
        fi
    done

    # ── Per-container checks (monitored, running) ─────────────────

    # get_ct_gpu_usage queries host-side nvidia-smi and does not depend on the
    # container id. Read it once per check cycle and reuse across containers
    # instead of fork-exec'ing nvidia-smi N times. Sentinel -1 means unread;
    # we populate it lazily on first use below.
    local ct_gpu_usage_cached="-1"
    local ct_gpu_read=0
    for id in $CONTAINER_IDS; do
        monitor=$(get_cfg "CONTAINER_${id}_MONITOR" "1")
        is_enabled "$monitor" || continue

        if ! ct_is_running "$id"; then
            debug "Container $id not running - idle for this instance"
            continue
        fi

        # GPU (host-side nvidia-smi — degrades gracefully when GPU is in vfio).
        # Cached across all containers in this cycle.
        local gpu_threshold; gpu_threshold=$(get_threshold "CONTAINER_${id}_GPU_IDLE_THRESHOLD" "$GPU_IDLE_THRESHOLD" "$DEFAULT_GPU_IDLE_THRESHOLD")
        if [[ "$ct_gpu_read" == "0" ]]; then
            ct_gpu_usage_cached=$(get_ct_gpu_usage)
            ct_gpu_read=1
        fi
        local gpu_usage="$ct_gpu_usage_cached"
        debug "Container $id host GPU usage: $gpu_usage%"
        if is_valid_metric "$gpu_usage" && [[ "$gpu_usage" -gt "$gpu_threshold" ]]; then
            debug "Container $id GPU active ($gpu_usage% > $gpu_threshold%)"
            return 1
        fi

        # CPU
        local cpu_threshold; cpu_threshold=$(get_threshold "CONTAINER_${id}_CPU_IDLE_THRESHOLD" "$CPU_IDLE_THRESHOLD" "$DEFAULT_CPU_IDLE_THRESHOLD")
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
                # Only stamp a wake time if a suspend actually happened. Stamping
                # it after a declined attempt restarts WAKE_GRACE_PERIOD, and a
                # grace period longer than the idle threshold then never expires.
                if trigger_sleep; then
                    record_wake_time
                fi
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
            if is_enabled "$check_user_idle"; then
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
            if ! is_enabled "$check_power"; then
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
    if ! is_enabled "$CHECK_SSH_SESSIONS"; then echo "DISABLED"
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
    if ! is_enabled "$CHECK_SLEEP_INHIBITORS"; then echo "DISABLED"
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
    # `status` never calls validate_config, so it has to survive a threshold
    # the daemon would have refused to start on. Arithmetic on a non-numeric
    # value aborts the whole subcommand under `set -u`.
    if ! is_positive_int "$IDLE_THRESHOLD_MINUTES"; then
        echo "Auto-sleep: MISCONFIGURED (IDLE_THRESHOLD_MINUTES='$IDLE_THRESHOLD_MINUTES' is not a non-negative integer)"
        return
    fi
    # record_idle_state() bails out at this threshold, so no tracking ever
    # starts — report that instead of a countdown that will not happen.
    if [[ "$IDLE_THRESHOLD_MINUTES" -le 0 ]]; then
        echo "Auto-sleep: DISABLED (IDLE_THRESHOLD_MINUTES=$IDLE_THRESHOLD_MINUTES)"
        return
    fi
    if is_system_idle; then
        local idle_start=""
        [[ -f "$STATE_FILE" ]] && idle_start=$(cat "$STATE_FILE")
        # Same guard the daemon path applies: a corrupt or empty state file
        # must not abort `status` under `set -u`, nor print a bogus countdown.
        if [[ -n "$idle_start" ]] && ! is_positive_int "$idle_start"; then
            echo "Idle Tracking: state file is corrupt, will reset on next check"
        elif [[ -n "$idle_start" ]]; then
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
        echo "  IDLE_THRESHOLD_MINUTES    - Minutes before sleep, 0 disables (default: 15)"
        echo "  GPU_VENDOR                - nvidia, amd, or auto (default: auto)"
        echo "  DEBUG=1                   - Enable debug logging"
        exit 1
        ;;
esac
