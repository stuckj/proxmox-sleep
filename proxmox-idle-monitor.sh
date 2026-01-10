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
CHECK_SSH_SESSIONS="${CHECK_SSH_SESSIONS:-1}"
# Grace period after wake - don't trigger sleep for this many seconds after waking
WAKE_GRACE_PERIOD="${WAKE_GRACE_PERIOD:-60}"
LOG_FILE="${IDLE_MONITOR_LOG:-/var/log/proxmox-idle-monitor.log}"
STATE_FILE="/tmp/proxmox-idle-monitor.state"
WAKE_TIME_FILE="/tmp/proxmox-idle-monitor.wake"

# Gaming processes - prevent sleep when these are running in Windows VM
# Set to empty string in config to disable gaming process detection
GAMING_PROCESSES="${GAMING_PROCESSES-steam.exe,EpicGamesLauncher.exe,GalaxyClient.exe,Battle.net.exe,origin.exe,upc.exe}"

# Host blocking processes - prevent sleep when these are running on the Proxmox host
# Set to empty string in config to disable host process detection
HOST_BLOCKING_PROCESSES="${HOST_BLOCKING_PROCESSES-}"

# Systemd units that should block sleep while active (comma-separated)
# Only include "oneshot" services that run temporarily during actual work.
# Don't include long-running daemons like unattended-upgrades.service (use HOST_BLOCKING_PROCESSES instead)
# Set to empty string in config to disable unit detection
HOST_BLOCKING_UNITS="${HOST_BLOCKING_UNITS-apt-daily.service,apt-daily-upgrade.service}"

# Check for systemd sleep inhibitors (applications blocking sleep)
# Set to 0 to disable sleep inhibitor detection
CHECK_SLEEP_INHIBITORS="${CHECK_SLEEP_INHIBITORS:-1}"

# Helper to parse JSON output from qm guest exec
# Extracts the value from "out-data" field
parse_guest_output() {
    local json="$1"
    # Remove newlines and extract out-data value (using sed for portability)
    # Also remove literal \r\n sequences from the JSON-escaped output
    echo "$json" | tr -d '\n\r' | sed -n 's/.*"out-data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/\\r\\n//g; s/\\r//g; s/\\n//g'
}

# Numeric validation helpers
# Check if value is a valid non-negative integer
is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Check if value is a valid integer (including negative)
is_integer() {
    [[ "$1" =~ ^-?[0-9]+$ ]]
}

# Check if value is a valid metric (integer and not -1, our error sentinel)
is_valid_metric() {
    is_integer "$1" && [[ "$1" != "-1" ]]
}

# Extract first integer from a string (handles negative numbers)
extract_int() {
    echo "$1" | grep -oE '^-?[0-9]+' | head -1
}

# Extract first positive integer from a string
extract_positive_int() {
    echo "$1" | grep -oE '^[0-9]+' | head -1
}

# Exit codes (from sysexits.h)
EX_OK=0
EX_CONFIG=78  # Configuration error

# Validate configuration before starting
# Returns 0 if valid, exits with EX_CONFIG if invalid
validate_config() {
    local errors=0

    # Check if config file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
        echo "       Copy the example config and edit it:" >&2
        echo "       cp /usr/share/doc/proxmox-sleep/examples/proxmox-sleep.conf.example /etc/proxmox-sleep.conf" >&2
        exit $EX_CONFIG
    fi

    # Check if VMID is set and VM exists
    if [[ -z "$VMID" ]]; then
        echo "ERROR: VMID is not set in $CONFIG_FILE" >&2
        errors=$((errors + 1))
    elif ! qm status "$VMID" &>/dev/null; then
        echo "ERROR: VM $VMID does not exist" >&2
        echo "       Edit $CONFIG_FILE and set the correct VMID" >&2
        errors=$((errors + 1))
    fi

    # Check idle threshold is a non-negative integer (0 disables auto-sleep)
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

# Logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        # Write only to log file, not stdout (to avoid polluting function return values)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - DEBUG: $1" >> "$LOG_FILE"
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
    extract_positive_int "$output"
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
    extract_int "$output"
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
    extract_int "$output"
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
    local cpu json node_name
    node_name=$(hostname 2>/dev/null)
    if [[ -z "$node_name" ]]; then
        debug "Failed to get hostname"
        echo "-1"
        return
    fi
    json=$(pvesh get /nodes/$node_name/qemu/$VMID/status/current --output-format json 2>/dev/null)
    # Handle multi-line JSON - remove newlines and parse (using sed for portability)
    cpu=$(echo "$json" | tr -d '\n\r' | sed -n 's/.*"cpu"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1)
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
    sessions=$(who | grep -c pts 2>/dev/null | head -1)
    sessions="${sessions:-0}"
    is_positive_int "$sessions" && [[ "$sessions" -gt 0 ]]
}

# Check Windows idle time via guest agent
# Reads from a file that's updated by a helper running in the user's session
# Falls back to screensaver/lock detection if helper isn't installed
get_windows_idle_time() {
    local result output idle_seconds

    # First, try to read from the idle helper file (updated by user-session helper)
    result=$(qm guest exec "$VMID" -- powershell -Command '
        $idleFile = "$env:ProgramData\proxmox-idle\idle_seconds.txt"
        if (Test-Path $idleFile) {
            $content = Get-Content $idleFile -ErrorAction SilentlyContinue
            $fileTime = (Get-Item $idleFile).LastWriteTime
            $age = (Get-Date) - $fileTime
            # If file is fresh (< 30 seconds old), use it
            if ($age.TotalSeconds -lt 30) {
                Write-Output $content
                return
            }
        }
        # Helper not running or stale - return -1
        Write-Output "-1"
    ' 2>/dev/null)

    output=$(parse_guest_output "$result")
    idle_seconds=$(extract_int "$output")

    # If we got a valid value from the helper, use it
    if is_valid_metric "$idle_seconds"; then
        echo "$idle_seconds"
        return
    fi

    # Fallback: Check screensaver/lock status
    # If screensaver is running or screen is locked, consider very idle
    result=$(qm guest exec "$VMID" -- powershell -Command '
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
            # Screensaver/lock = very idle, return large value
            Write-Output "99999"
        } else {
            # Cannot determine - return -1
            Write-Output "-1"
        }
    ' 2>/dev/null)

    output=$(parse_guest_output "$result")
    idle_seconds=$(extract_int "$output")
    echo "${idle_seconds:--1}"
}

# Install the idle helper in Windows (run once)
install_windows_idle_helper() {
    echo "Installing Windows idle helper in VM $VMID..."

    # First, create the helper script by writing it in parts to avoid escaping issues
    qm guest exec "$VMID" -- powershell -Command '
        $helperDir = "$env:ProgramData\proxmox-idle"
        if (-not (Test-Path $helperDir)) {
            New-Item -ItemType Directory -Path $helperDir -Force | Out-Null
        }

        # Write the C# code to a separate file
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

    # Now create the main script with tray icon
    qm guest exec "$VMID" -- powershell -Command '
        $helperDir = "$env:ProgramData\proxmox-idle"
        $script = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Load idle time code
`$csCode = Get-Content "`$env:ProgramData\proxmox-idle\IdleTime.cs" -Raw
Add-Type -TypeDefinition `$csCode

# Create tray icon
`$trayIcon = New-Object System.Windows.Forms.NotifyIcon
`$trayIcon.Icon = [System.Drawing.SystemIcons]::Information
`$trayIcon.Text = "Proxmox Idle Monitor"
`$trayIcon.Visible = `$true

# Create context menu
`$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
`$exitItem = `$contextMenu.Items.Add("Exit")
`$exitItem.Add_Click({
    `$trayIcon.Visible = `$false
    [System.Windows.Forms.Application]::Exit()
})
`$trayIcon.ContextMenuStrip = `$contextMenu

# Timer to update idle time
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

# Initial update
try {
    `$idle = [IdleTime]::GetIdleSeconds()
    `$idle | Set-Content "`$env:ProgramData\proxmox-idle\idle_seconds.txt" -Force
} catch {}

# Run message loop
[System.Windows.Forms.Application]::Run()
"@
        $script | Set-Content "$helperDir\idle_helper.ps1" -Force
        Write-Output "Script file created"
    ' 2>&1

    # Create a VBScript wrapper to launch PowerShell completely hidden (no window flash)
    qm guest exec "$VMID" -- powershell -Command '
        $helperDir = "$env:ProgramData\proxmox-idle"
        $vbs = @"
Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
psScript = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), fso.GetBaseName(WScript.ScriptFullName) & ".ps1")
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScript & """", 0, False
"@
        $vbs | Set-Content "$helperDir\idle_helper.vbs" -Force
        Write-Output "VBS launcher created"
    ' 2>&1

    # Create the scheduled task using the VBS wrapper
    qm guest exec "$VMID" -- powershell -Command '
        $helperDir = "$env:ProgramData\proxmox-idle"
        $helperVbs = "$helperDir\idle_helper.vbs"

        # Get the actual logged-in user (not SYSTEM which runs guest agent)
        $loggedInUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        if (-not $loggedInUser) {
            # Fallback: try to infer user from explorer.exe owner
            $explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($explorer) {
                $proc = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $explorer.Id) -ErrorAction SilentlyContinue
                if ($proc) {
                    $owner = $proc.GetOwner()
                    if ($owner -and $owner.User) {
                        $loggedInUser = $owner.User
                    }
                }
            }
        }
        if (-not $loggedInUser) {
            throw "Unable to determine logged-in user for scheduled task registration"
        }
        Write-Output "User: $loggedInUser"

        # Remove old task if exists
        Unregister-ScheduledTask -TaskName "ProxmoxIdleHelper" -Confirm:$false -ErrorAction SilentlyContinue
        Write-Output "Old task removed"

        # Clear old idle file
        Remove-Item "$helperDir\idle_seconds.txt" -Force -ErrorAction SilentlyContinue

        # Create and register task
        $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "//B //NoLogo `"$helperVbs`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 9999)
        Register-ScheduledTask -TaskName "ProxmoxIdleHelper" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Output "Task registered"
    ' 2>&1

    # Start the task
    qm guest exec "$VMID" -- schtasks /run /tn ProxmoxIdleHelper 2>&1

    echo "Waiting for helper to initialize..."
    sleep 5

    # Verify it's working
    local result
    result=$(qm guest exec "$VMID" -- powershell -Command '
        $idleFile = "$env:ProgramData\proxmox-idle\idle_seconds.txt"
        if (Test-Path $idleFile) {
            "OK: " + (Get-Content $idleFile)
        } else {
            "FAIL: File not created. Checking task status..."
            $task = Get-ScheduledTaskInfo -TaskName ProxmoxIdleHelper
            "Last result: " + $task.LastTaskResult
        }
    ' 2>/dev/null)
    echo "Result: $(parse_guest_output "$result")"
}

# Uninstall the idle helper from Windows
uninstall_windows_idle_helper() {
    echo "Uninstalling Windows idle helper from VM $VMID..."

    # Remove scheduled task using schtasks (faster than PowerShell)
    qm guest exec "$VMID" -- schtasks /delete /tn ProxmoxIdleHelper /f 2>&1

    # Kill only wscript.exe processes running our idle helper (not all wscript processes)
    qm guest exec "$VMID" -- powershell -Command '
        Get-CimInstance Win32_Process -Filter "Name=''wscript.exe''" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*idle_helper.vbs*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Write-Output "Processes killed"
    ' 2>&1

    # Remove helper files
    qm guest exec "$VMID" -- cmd /c 'rmdir /s /q "%ProgramData%\proxmox-idle" 2>nul & echo Files removed' 2>&1

    echo "Done."
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

# Check if any host blocking processes are running on the Proxmox host
# These prevent sleep when actively running (e.g., unattended-upgrade during updates)
check_host_blocking_processes() {
    # Skip if no host blocking processes configured
    if [[ -z "$HOST_BLOCKING_PROCESSES" ]]; then
        debug "Host blocking process detection disabled (empty list)"
        return 1  # No processes to check = not detected
    fi

    # Convert comma-separated list to array
    IFS=',' read -ra blocking_procs <<< "$HOST_BLOCKING_PROCESSES"

    for proc in "${blocking_procs[@]}"; do
        # Trim whitespace
        proc=$(echo "$proc" | xargs)
        [[ -z "$proc" ]] && continue

        # Check if process is running using pgrep
        if pgrep -x "$proc" > /dev/null 2>&1; then
            debug "Found host blocking process: $proc"
            return 0  # Blocking process found
        fi
    done

    return 1  # No blocking processes found
}

# Check if any systemd units are active that should block sleep
# (e.g., apt-daily.service, unattended-upgrades.service)
check_host_blocking_units() {
    # Skip if no blocking units configured
    if [[ -z "$HOST_BLOCKING_UNITS" ]]; then
        debug "Host blocking unit detection disabled (empty list)"
        return 1  # No units to check = not detected
    fi

    # Convert comma-separated list to array
    IFS=',' read -ra blocking_units <<< "$HOST_BLOCKING_UNITS"

    for unit in "${blocking_units[@]}"; do
        # Trim whitespace
        unit=$(echo "$unit" | xargs)
        [[ -z "$unit" ]] && continue

        # Check if unit is active using systemctl
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            debug "Found active blocking unit: $unit"
            return 0  # Blocking unit is active
        fi
    done

    return 1  # No blocking units active
}

# Get list of active blocking units (for display)
get_active_blocking_units() {
    if [[ -z "$HOST_BLOCKING_UNITS" ]]; then
        echo "none"
        return
    fi

    local active_units=()
    IFS=',' read -ra blocking_units <<< "$HOST_BLOCKING_UNITS"

    for unit in "${blocking_units[@]}"; do
        unit=$(echo "$unit" | xargs)
        [[ -z "$unit" ]] && continue
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            active_units+=("$unit")
        fi
    done

    if [[ ${#active_units[@]} -eq 0 ]]; then
        echo "none"
    else
        echo "${active_units[*]}"
    fi
}

# Check if there are systemd sleep inhibitors that would block/delay sleep
# Only checks for inhibitors with "sleep" in the What field
check_sleep_inhibitors() {
    # Skip if sleep inhibitor check is disabled
    if [[ "$CHECK_SLEEP_INHIBITORS" != "1" ]]; then
        debug "Sleep inhibitor detection disabled"
        return 1  # Check disabled = not detected
    fi

    # Get list of inhibitors and check for sleep-blocking ones
    # systemd-inhibit --list format: WHO, UID, PID, WHAT, WHY, MODE
    # We look for inhibitors where WHAT contains "sleep" and MODE is "block" or "delay"
    local inhibitor_list
    inhibitor_list=$(systemd-inhibit --list --no-legend 2>/dev/null)

    if [[ -z "$inhibitor_list" ]]; then
        debug "No sleep inhibitors found"
        return 1  # No inhibitors
    fi

    # Parse each line and check for sleep inhibitors
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # The WHAT field can contain multiple colon-separated values like "sleep:shutdown"
        # We need to check if "sleep" is one of them
        # Column layout: WHO UID PID WHAT WHY MODE
        # Using awk to get the WHAT field (4th column) and MODE field (last column)
        local what mode
        what=$(echo "$line" | awk '{print $4}')
        mode=$(echo "$line" | awk '{print $NF}')

        # Check if this inhibitor blocks or delays sleep
        if [[ "$what" == *"sleep"* ]] && [[ "$mode" == "block" || "$mode" == "delay" ]]; then
            debug "Found sleep inhibitor: $line"
            return 0  # Sleep inhibitor found
        fi
    done <<< "$inhibitor_list"

    debug "No sleep-blocking inhibitors found"
    return 1  # No sleep inhibitors
}

# Get details of active sleep inhibitors (for display)
get_sleep_inhibitors_detail() {
    if [[ "$CHECK_SLEEP_INHIBITORS" != "1" ]]; then
        echo "disabled"
        return
    fi

    local inhibitor_list
    inhibitor_list=$(systemd-inhibit --list --no-legend 2>/dev/null)

    if [[ -z "$inhibitor_list" ]]; then
        echo "none"
        return
    fi

    local details=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local what mode who why
        what=$(echo "$line" | awk '{print $4}')
        mode=$(echo "$line" | awk '{print $NF}')
        who=$(echo "$line" | awk '{print $1}')
        # WHY is the 5th field but can contain spaces, so we extract it more carefully
        # Skip first 4 fields and last field to get WHY
        why=$(echo "$line" | awk '{$1=$2=$3=$4=""; $NF=""; print}' | xargs)

        if [[ "$what" == *"sleep"* ]] && [[ "$mode" == "block" || "$mode" == "delay" ]]; then
            details+=("$who: $why ($mode)")
        fi
    done <<< "$inhibitor_list"

    if [[ ${#details[@]} -eq 0 ]]; then
        echo "none"
    else
        printf '%s\n' "${details[@]}"
    fi
}

# Check if any Windows process is requesting the system stay awake
# This catches media players, downloads, presentations, etc.
# Filters out known system noise like AMD CPU power management
check_power_requests() {
    local result output
    result=$(qm guest exec "$VMID" -- powershell -Command '
        $requests = powercfg /requests
        $hasRequests = $false
        $currentCategory = ""

        # Known noise patterns to ignore (AMD CPU power management, etc.)
        $ignorePatterns = @(
            "Legacy Kernel Caller",
            "Sleep Idle State Disabled"
        )

        foreach ($line in $requests -split "`n") {
            $line = $line.Trim()
            # Match any category header (DISPLAY:, SYSTEM:, ACTIVELOCKSCREEN:, etc.)
            if ($line -match "^[A-Z]+:$") {
                $currentCategory = $line
            }
            elseif ($line -and $line -ne "None." -and $currentCategory) {
                # Check if this matches any ignore pattern
                $ignore = $false
                foreach ($pattern in $ignorePatterns) {
                    if ($line -like "*$pattern*") {
                        $ignore = $true
                        break
                    }
                }
                if (-not $ignore) {
                    $hasRequests = $true
                    break
                }
            }
        }
        if ($hasRequests) { "ACTIVE" } else { "NONE" }
    ' 2>/dev/null)
    output=$(parse_guest_output "$result")

    if [[ "$output" == "ACTIVE" ]]; then
        debug "Windows power requests active (process keeping system awake)"
        return 0  # Power request active
    fi
    return 1  # No power requests
}

# Get details of active power requests (for display)
# Filters out known system noise
get_power_requests_detail() {
    local result output
    result=$(qm guest exec "$VMID" -- powershell -Command '
        $requests = powercfg /requests
        $active = @()
        $currentCategory = ""

        # Known noise patterns to ignore
        $ignorePatterns = @(
            "Legacy Kernel Caller",
            "Sleep Idle State Disabled"
        )

        foreach ($line in $requests -split "`n") {
            $line = $line.Trim()
            # Match any category header (DISPLAY:, SYSTEM:, ACTIVELOCKSCREEN:, etc.)
            if ($line -match "^[A-Z]+:$") {
                $currentCategory = $line -replace ":$",""
            }
            elseif ($line -and $line -ne "None." -and $currentCategory) {
                # Check if this matches any ignore pattern
                $ignore = $false
                foreach ($pattern in $ignorePatterns) {
                    if ($line -like "*$pattern*") {
                        $ignore = $true
                        break
                    }
                }
                if (-not $ignore) {
                    $active += "$currentCategory : $line"
                }
            }
        }
        if ($active.Count -gt 0) { $active -join "; " } else { "None" }
    ' 2>/dev/null)
    output=$(parse_guest_output "$result")
    echo "${output:-None}"
}

# Get seconds since last wake (or -1 if no wake recorded)
get_seconds_since_wake() {
    if [[ ! -f "$WAKE_TIME_FILE" ]]; then
        echo "-1"
        return
    fi

    local wake_time current_time
    wake_time=$(cat "$WAKE_TIME_FILE")
    current_time=$(date +%s)
    echo $((current_time - wake_time))
}

# Record that system just woke up
record_wake_time() {
    date +%s > "$WAKE_TIME_FILE"
    log "Wake time recorded - idle timer reset"
}

# Clear wake time
clear_wake_time() {
    rm -f "$WAKE_TIME_FILE"
}

# Get effective idle time (accounts for wake time)
# If Windows idle time predates wake, use time since wake instead
get_effective_idle_time() {
    local win_idle seconds_since_wake

    win_idle=$(get_windows_idle_time)
    seconds_since_wake=$(get_seconds_since_wake)

    if [[ "$win_idle" == "-1" ]]; then
        echo "-1"
        return
    fi

    # Validate Windows idle is a valid integer
    if ! is_positive_int "$win_idle"; then
        debug "Invalid Windows idle time value: '$win_idle'"
        echo "-1"
        return
    fi

    # If no wake time recorded (-1), just use Windows idle time directly
    if [[ "$seconds_since_wake" == "-1" ]]; then
        echo "$win_idle"
        return
    fi

    # Validate seconds_since_wake is a valid integer
    if ! is_positive_int "$seconds_since_wake"; then
        debug "Invalid seconds since wake value: '$seconds_since_wake'"
        echo "$win_idle"  # Fall back to Windows idle time
        return
    fi

    # If Windows idle time > time since wake, user hasn't been active since wake
    # So effective idle time is just time since wake
    if [[ $win_idle -gt $seconds_since_wake ]]; then
        debug "Windows idle ($win_idle) > time since wake ($seconds_since_wake), using wake time"
        echo "$seconds_since_wake"
    else
        # User was active after wake, Windows idle time is valid
        echo "$win_idle"
    fi
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
    if is_valid_metric "$gpu_usage" && [[ "$gpu_usage" -gt "$GPU_IDLE_THRESHOLD" ]]; then
        debug "GPU active ($gpu_usage% > $GPU_IDLE_THRESHOLD%)"
        return 1  # GPU is active
    fi

    # Check 3: VM CPU usage
    local cpu_usage
    cpu_usage=$(get_vm_cpu_usage)
    debug "VM CPU usage: $cpu_usage%"
    if is_valid_metric "$cpu_usage" && [[ "$cpu_usage" -gt "$CPU_IDLE_THRESHOLD" ]]; then
        debug "VM CPU active ($cpu_usage% > $CPU_IDLE_THRESHOLD%)"
        return 1  # CPU is active
    fi

    # Check 4: SSH sessions to host
    if [[ "$CHECK_SSH_SESSIONS" == "1" ]] && has_active_ssh_sessions; then
        debug "Active SSH sessions detected"
        return 1  # Someone is connected
    fi

    # Check 5: Effective idle time (accounts for wake time)
    local effective_idle
    effective_idle=$(get_effective_idle_time)
    debug "Effective idle time: ${effective_idle}s"
    local idle_threshold_seconds=$((IDLE_THRESHOLD_MINUTES * 60))
    if is_valid_metric "$effective_idle" && [[ "$effective_idle" -lt "$idle_threshold_seconds" ]]; then
        debug "User recently active (${effective_idle}s < ${idle_threshold_seconds}s)"
        return 1  # User recently active
    fi

    # Check 6: Gaming processes (optional extra check)
    if check_gaming_processes; then
        debug "Gaming processes detected"
        return 1  # Gaming in progress
    fi

    # Check 7: Windows power requests (media players, downloads, etc.)
    if check_power_requests; then
        debug "Windows power requests active"
        return 1  # Something is keeping Windows awake
    fi

    # Check 8: Host blocking processes (e.g., unattended-upgrade)
    if check_host_blocking_processes; then
        debug "Host blocking processes running"
        return 1  # Host process is blocking sleep
    fi

    # Check 9: Host blocking systemd units (e.g., apt-daily.service)
    if check_host_blocking_units; then
        debug "Host blocking units active"
        return 1  # Systemd unit is blocking sleep
    fi

    # Check 10: Systemd sleep inhibitors (applications blocking sleep)
    if check_sleep_inhibitors; then
        debug "Sleep inhibitors active"
        return 1  # Sleep inhibitor is active
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
        return 1  # Not yet time to sleep, just started tracking
    fi

    local idle_start
    idle_start=$(cat "$STATE_FILE")

    # Validate idle_start is a valid non-negative integer
    if ! is_positive_int "$idle_start"; then
        log "Invalid idle start timestamp in $STATE_FILE ('$idle_start'), resetting idle state"
        echo "$current_time" > "$STATE_FILE"
        return 1  # Treat as not yet time to sleep
    fi

    local idle_seconds=$(( current_time - idle_start ))

    # Guard against negative durations due to clock adjustments
    if (( idle_seconds < 0 )); then
        log "Negative idle duration detected (clock adjusted?), resetting idle state"
        echo "$current_time" > "$STATE_FILE"
        return 1  # Treat as not yet time to sleep
    fi

    local idle_duration=$(( idle_seconds / 60 ))

    # Sanity check: If idle tracking started before the last wake, the state is stale
    # This catches cases where the state file persisted across sleep/wake cycles
    if [[ -f "$WAKE_TIME_FILE" ]]; then
        local wake_time
        wake_time=$(cat "$WAKE_TIME_FILE")
        if is_positive_int "$wake_time" && [[ "$idle_start" -lt "$wake_time" ]]; then
            log "Stale idle state detected (idle tracking started before last wake), resetting"
            echo "$current_time" > "$STATE_FILE"
            return 1  # Treat as not yet time to sleep
        fi
    fi

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
    # Safety check: Don't trigger sleep if we just woke up
    # This prevents race conditions where stale state causes immediate re-sleep
    local seconds_since_wake
    seconds_since_wake=$(get_seconds_since_wake)

    # Only apply grace period if we have a valid wake time (-1 means no wake recorded)
    if [[ "$seconds_since_wake" != "-1" ]] && is_positive_int "$seconds_since_wake" && [[ "$seconds_since_wake" -lt "$WAKE_GRACE_PERIOD" ]]; then
        log "Within wake grace period (${seconds_since_wake}s < ${WAKE_GRACE_PERIOD}s), skipping sleep"
        reset_idle_state
        return 1
    fi

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
                # After wake, record wake time to reset idle timer
                record_wake_time
                sleep 10  # Brief pause for system stability
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
        local win_idle eff_idle
        win_idle=$(get_windows_idle_time)
        eff_idle=$(get_effective_idle_time)
        echo "Windows Idle Time: ${win_idle} seconds"
        echo "Effective Idle Time: ${eff_idle} seconds (accounts for wake)"

        echo ""
        echo -n "Gaming Processes: "
        if [[ -z "$GAMING_PROCESSES" ]]; then
            echo "DISABLED"
        elif check_gaming_processes; then
            echo "DETECTED"
        else
            echo "none"
        fi

        echo ""
        echo -n "Power Requests: "
        if check_power_requests; then
            echo "ACTIVE"
            echo "  $(get_power_requests_detail)"
        else
            echo "none"
        fi
    else
        echo "  Running: NO"
    fi

    echo ""
    echo -n "SSH Sessions: "
    if [[ "$CHECK_SSH_SESSIONS" != "1" ]]; then
        echo "DISABLED"
    elif has_active_ssh_sessions; then
        echo "YES"
    else
        echo "NO"
    fi

    echo ""
    echo -n "Host Blocking Processes: "
    if [[ -z "$HOST_BLOCKING_PROCESSES" ]]; then
        echo "DISABLED"
    elif check_host_blocking_processes; then
        echo "DETECTED"
    else
        echo "none"
    fi

    echo ""
    echo -n "Host Blocking Units: "
    if [[ -z "$HOST_BLOCKING_UNITS" ]]; then
        echo "DISABLED"
    elif check_host_blocking_units; then
        echo "ACTIVE"
        echo "  $(get_active_blocking_units)"
    else
        echo "none"
    fi

    echo ""
    echo -n "Sleep Inhibitors: "
    if [[ "$CHECK_SLEEP_INHIBITORS" != "1" ]]; then
        echo "DISABLED"
    elif check_sleep_inhibitors; then
        echo "ACTIVE"
        get_sleep_inhibitors_detail | sed 's/^/  /'
    else
        echo "none"
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
    # Check if system is currently idle
    if is_system_idle; then
        if [[ -f "$STATE_FILE" ]]; then
            local idle_start
            idle_start=$(cat "$STATE_FILE")
            local current_time
            current_time=$(date +%s)
            local idle_duration=$(( (current_time - idle_start) / 60 ))
            echo "Idle Tracking: Counting down - ${idle_duration}/${IDLE_THRESHOLD_MINUTES} minutes"
            local remaining=$((IDLE_THRESHOLD_MINUTES - idle_duration))
            if (( remaining <= 0 )); then
                echo "Sleep in: imminent"
            else
                echo "Sleep in: ${remaining} minutes"
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

# Main
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
        install_windows_idle_helper
        ;;
    uninstall-helper)
        uninstall_windows_idle_helper
        ;;
    *)
        echo "Usage: $0 {start|check|status|reset|sleep-now|install-helper|uninstall-helper}"
        echo ""
        echo "Commands:"
        echo "  start            - Start the monitoring daemon"
        echo "  check            - One-time idle check (for testing)"
        echo "  status           - Show current status"
        echo "  reset            - Reset idle tracking"
        echo "  sleep-now        - Immediately hibernate VM and sleep the host"
        echo "  install-helper   - Install Windows idle helper (required for KB/mouse tracking)"
        echo "  uninstall-helper - Remove Windows idle helper from VM"
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
