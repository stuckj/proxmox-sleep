# Proxmox Sleep Manager - Design Documentation

This document provides a comprehensive technical overview of the Proxmox Sleep Manager architecture, components, and design decisions.

## Table of Contents

- [Problem Statement](#problem-statement)
- [Solution Overview](#solution-overview)
- [Architecture](#architecture)
- [Component Details](#component-details)
- [Data Flow](#data-flow)
- [State Management](#state-management)
- [Configuration System](#configuration-system)
- [Error Handling](#error-handling)
- [Security Considerations](#security-considerations)
- [Future Considerations](#future-considerations)

---

## Problem Statement

### The Challenge

Running Windows VMs with GPU passthrough on Proxmox hosts presents a significant power management challenge:

1. **Native S3 Sleep Limitations**: Hardware sleep (S3/S2idle) with GPU passthrough is unreliable because:
   - GPUs often lack proper Function Level Reset (FLR) support
   - PCIe device state doesn't survive host sleep/wake cycles
   - Resume can cause VM crashes, kernel panics, or ZFS corruption

2. **Power Consumption**: Leaving a powerful workstation running 24/7 wastes significant electricity when not in use.

3. **User Experience**: Users want their Windows VM to "just work" when they return, similar to a laptop waking from sleep.

### Why Existing Solutions Fall Short

- **VM Suspend (QEMU savestate)**: Doesn't release GPU resources, host still can't sleep
- **VM Shutdown**: Loses session state, requires full boot on wake
- **Native S3 with GPU**: High failure rate, data corruption risk
- **Manual hibernation**: Requires user intervention, defeats automation purpose

---

## Solution Overview

### Core Approach

Use **Windows hibernation** as a VM state preservation mechanism, decoupled from host sleep:

1. **Before host sleep**: Hibernate the Windows VM (saves RAM to disk, releases all hardware)
2. **Host sleeps**: With no VMs running, host enters safe S3/S2idle state
3. **Host wakes**: Start the VM, which automatically resumes from hibernation

### Key Innovation

By using Windows' own hibernation instead of QEMU's savestate:
- GPU is properly released (Windows shuts down, QEMU exits)
- VM state is safely persisted (hiberfil.sys on Windows disk)
- Resume is handled by Windows (native, reliable)
- Host can safely enter deep sleep states

### Two-Component Design

| Component | Role | Execution Model |
|-----------|------|-----------------|
| **Sleep Manager** | Orchestrates VM hibernation/resume around host sleep | Systemd hook (oneshot) |
| **Idle Monitor** | Detects inactivity and triggers host sleep | Systemd daemon (long-running) |

---

## Architecture

### High-Level Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Proxmox Host                                    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        Systemd                                       │   │
│  │  ┌─────────────────────┐    ┌──────────────────────────────────┐   │   │
│  │  │ sleep.target        │    │ proxmox-idle-monitor.service     │   │   │
│  │  │ (Before/After)      │    │ (Type=simple, always running)    │   │   │
│  │  └──────────┬──────────┘    └───────────────┬──────────────────┘   │   │
│  │             │                               │                       │   │
│  │             ▼                               ▼                       │   │
│  │  ┌─────────────────────┐    ┌──────────────────────────────────┐   │   │
│  │  │ proxmox-sleep-      │    │ proxmox-idle-monitor.sh          │   │   │
│  │  │ manager.service     │    │ (Polls every 60s)                │   │   │
│  │  │ (Type=oneshot)      │    │                                  │   │   │
│  │  └──────────┬──────────┘    └───────────────┬──────────────────┘   │   │
│  └─────────────┼───────────────────────────────┼───────────────────────┘   │
│                │                               │                           │
│                ▼                               ▼                           │
│  ┌─────────────────────────┐    ┌──────────────────────────────────────┐   │
│  │ proxmox-sleep-manager.sh│    │         Activity Checks              │   │
│  │                         │    │  ┌────────────┐ ┌──────────────┐     │   │
│  │  • pre_sleep()          │    │  │ VM CPU %   │ │ GPU Usage    │     │   │
│  │  • post_wake()          │    │  └────────────┘ └──────────────┘     │   │
│  │  • hibernate_vm()       │    │  ┌────────────┐ ┌──────────────┐     │   │
│  │  • resume_vm()          │    │  │ User Idle  │ │ Power Reqs   │     │   │
│  └───────────┬─────────────┘    │  └────────────┘ └──────────────┘     │   │
│              │                  │  ┌────────────┐ ┌──────────────┐     │   │
│              ▼                  │  │ Gaming     │ │ SSH Sessions │     │   │
│  ┌─────────────────────────┐    │  └────────────┘ └──────────────┘     │   │
│  │    Proxmox API (pvesh)  │    │  ┌────────────┐ ┌──────────────┐     │   │
│  │    VM Control (qm)      │    │  │ Host Procs │ │ Inhibitors   │     │   │
│  └───────────┬─────────────┘    │  └────────────┘ └──────────────┘     │   │
│              │                  └───────────────┬──────────────────────┘   │
│              ▼                                  │                          │
│  ┌─────────────────────────────────────────────┼────────────────────────┐  │
│  │                    Windows VM (QEMU/KVM)    │                        │  │
│  │                                             ▼                        │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │  │
│  │  │ QEMU Guest   │  │ GPU (passed  │  │ Idle Helper (Scheduled   │   │  │
│  │  │ Agent        │  │ through)     │  │ Task)                    │   │  │
│  │  │              │  │              │  │                          │   │  │
│  │  │ Receives:    │  │ nvidia-smi   │  │ • Tracks KB/Mouse idle   │   │  │
│  │  │ • shutdown   │  │ or AMD perf  │  │ • Writes idle_seconds.txt│   │  │
│  │  │ • exec cmds  │  │ counters     │  │ • Tray icon display      │   │  │
│  │  └──────────────┘  └──────────────┘  └──────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component Interaction Sequence

```
┌──────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────┐
│  User    │     │Idle Monitor  │     │Sleep Manager │     │Windows VM│
└────┬─────┘     └──────┬───────┘     └──────┬───────┘     └────┬─────┘
     │                  │                    │                  │
     │  Leaves system   │                    │                  │
     │─ ─ ─ ─ ─ ─ ─ ─ ─>│                    │                  │
     │                  │                    │                  │
     │                  │ Poll activity (60s intervals)        │
     │                  │─────────────────────────────────────>│
     │                  │<─────────────────────────────────────│
     │                  │ (All checks: IDLE)                   │
     │                  │                    │                  │
     │                  │ (15 min threshold reached)           │
     │                  │                    │                  │
     │                  │ systemctl suspend  │                  │
     │                  │───────────────────>│                  │
     │                  │                    │                  │
     │                  │                    │ pre_sleep()      │
     │                  │                    │─────────────────>│
     │                  │                    │ shutdown /h      │
     │                  │                    │<─────────────────│
     │                  │                    │ (VM hibernates)  │
     │                  │                    │                  │
     │                  │                    │ (Host enters S3) │
     │                  │                    │                  │
     ═══════════════════════════════════════════════════════════
     │                  │                    │                  │
     │  Returns/WoL     │                    │                  │
     │─ ─ ─ ─ ─ ─ ─ ─ ─>│                    │                  │
     │                  │                    │                  │
     │                  │                    │ post_wake()      │
     │                  │                    │─────────────────>│
     │                  │                    │ qm start         │
     │                  │                    │<─────────────────│
     │                  │                    │ (VM resumes)     │
     │                  │                    │                  │
     │                  │ Grace period (60s) │                  │
     │                  │<───────────────────│                  │
     │                  │                    │                  │
     │                  │ Resume monitoring  │                  │
     │                  │─────────────────────────────────────>│
```

---

## Component Details

### Sleep Manager (`proxmox-sleep-manager.sh`)

**Purpose**: Orchestrate VM hibernation when host sleeps, and VM resume when host wakes.

**Execution Context**: Runs as a systemd oneshot service, triggered by sleep.target.

#### Key Functions

| Function | Trigger | Description |
|----------|---------|-------------|
| `pre_sleep()` | `ExecStart` (Before sleep.target) | Hibernates VM, waits for completion |
| `post_wake()` | `ExecStop` (After wake) | Resumes VM from hibernation |
| `hibernate_vm()` | Called by pre_sleep | Sends `shutdown /h` via guest agent |
| `resume_vm()` | Called by post_wake | Issues `qm start` |
| `wait_for_hibernation()` | Called by hibernate_vm | Polls until QEMU exits |

#### Systemd Service Configuration

```ini
[Unit]
Description=Proxmox Sleep Manager
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/proxmox-sleep-manager.sh pre-sleep
ExecStop=/usr/local/bin/proxmox-sleep-manager.sh post-wake

[Install]
WantedBy=sleep.target
```

**Design Rationale**:
- `Before=sleep.target`: Ensures VM hibernates before host sleeps
- `RemainAfterExit=yes`: Keeps unit "active" so ExecStop runs on wake
- `StopWhenUnneeded=yes`: Triggers ExecStop when sleep.target deactivates

#### Hibernation Sequence Detail

```
pre_sleep()
    │
    ├─ Check VM exists (qm status)
    │   └─ Exit if VM doesn't exist
    │
    ├─ Check VM is running
    │   └─ Exit success if already stopped (nothing to hibernate)
    │
    ├─ Verify guest agent responds (timeout 10s)
    │   └─ Log warning if unresponsive, attempt anyway
    │
    ├─ Send hibernation command
    │   │   qm guest exec $VMID -- powershell -Command "shutdown /h"
    │   │
    │   └─ Alternative: qm guest cmd $VMID shutdown --mode hibernate
    │
    ├─ Wait for hibernation (poll every 5s, max HIBERNATE_TIMEOUT)
    │   │
    │   ├─ Check VM status via qm status
    │   ├─ Check QEMU process via pgrep
    │   └─ Require 2 consecutive "stopped" readings
    │
    ├─ Record state to /tmp/proxmox-sleep-manager.state
    │   └─ Contains: "hibernated" or "was_stopped"
    │
    └─ Return success (allow host to sleep)
```

### Idle Monitor (`proxmox-idle-monitor.sh`)

**Purpose**: Continuously monitor system activity and trigger host sleep when idle threshold is reached.

**Execution Context**: Runs as a long-running systemd daemon.

#### Idle Detection Hierarchy

The monitor performs multiple activity checks. **All checks must indicate idle** for the system to be considered inactive:

```
                        ┌─────────────────┐
                        │  Idle Monitor   │
                        │   Main Loop     │
                        └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
     ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
     │ VM-Level       │ │ Windows-Level  │ │ Host-Level     │
     │ Checks         │ │ Checks         │ │ Checks         │
     └───────┬────────┘ └───────┬────────┘ └───────┬────────┘
             │                  │                  │
    ┌────────┴────────┐  ┌──────┴──────┐   ┌──────┴──────┐
    │                 │  │             │   │             │
    ▼                 ▼  ▼             ▼   ▼             ▼
┌────────┐      ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│VM CPU %│      │GPU %   │ │User    │ │Power   │ │Gaming  │ │SSH     │
│(pvesh) │      │(nvidia/│ │Idle    │ │Requests│ │Procs   │ │Sessions│
│        │      │amd)    │ │(helper)│ │        │ │        │ │        │
└────────┘      └────────┘ └────────┘ └────────┘ └────────┘ └────────┘
                                │
                          ┌─────┴─────┐
                          │           │
                          ▼           ▼
                    ┌────────┐  ┌────────────┐
                    │Host    │  │Systemd     │
                    │Blocking│  │Inhibitors  │
                    │Procs   │  │            │
                    └────────┘  └────────────┘
```

#### Activity Check Details

| Check | Method | Active If | Default Threshold |
|-------|--------|-----------|-------------------|
| VM CPU | `pvesh get /nodes/.../status` | CPU% > threshold | 15% |
| GPU Usage | `nvidia-smi` or AMD perf counters | GPU% > threshold | 10% |
| User Idle | Idle helper file or screensaver query | Idle time < threshold | 15 min |
| Power Requests | `powercfg /requests` via guest agent | Any active request | N/A |
| Gaming | Process list via guest agent | Gaming process found | steam.exe, etc. |
| SSH Sessions | `who` or `ss` on host | Any SSH session | N/A |
| Host Processes | `pgrep` for blocking processes | Process running | unattended-upgrade |
| Systemd Units | `systemctl is-active` | Unit active | apt-daily.service |
| Sleep Inhibitors | `systemd-inhibit --list` | Any inhibitor | N/A |
| Wake Grace | Compare current time to wake file | Within grace period | 60s |

#### Windows Idle Helper

A critical component for accurate idle detection with USB passthrough:

```
┌────────────────────────────────────────────────────────────────┐
│                     Windows VM                                  │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              Scheduled Task (runs every 10s)              │  │
│  │                                                          │  │
│  │  PowerShell Script:                                      │  │
│  │  1. Call GetLastInputInfo() Win32 API                    │  │
│  │  2. Calculate seconds since last input                   │  │
│  │  3. Write to idle_seconds.txt                            │  │
│  │  4. Update tray icon tooltip                             │  │
│  └────────────────────────────────┬─────────────────────────┘  │
│                                   │                            │
│                                   ▼                            │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  C:\ProgramData\proxmox-idle\                          │    │
│  │  ├── idle_seconds.txt    ← "142" (seconds idle)        │    │
│  │  ├── check-idle.ps1      ← Idle check script           │    │
│  │  └── tray-icon.ps1       ← System tray helper          │    │
│  └────────────────────────────────────────────────────────┘    │
│                                   │                            │
└───────────────────────────────────┼────────────────────────────┘
                                    │
                                    │ qm guest exec (read file)
                                    │
                                    ▼
                          ┌──────────────────┐
                          │   Idle Monitor   │
                          │ (Proxmox Host)   │
                          └──────────────────┘
```

**Why a helper is needed**: When USB devices (keyboard/mouse) are passed through to the VM, the host has no visibility into input activity. The helper bridges this gap.

---

## Data Flow

### Configuration Loading

```
┌─────────────────────────────────────────────────────────────┐
│                    Configuration Sources                     │
│                                                             │
│   Priority (highest to lowest):                             │
│   1. Environment variables (override everything)            │
│   2. /etc/proxmox-sleep.conf (main config file)            │
│   3. Built-in defaults (in script)                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    load_config()                            │
│                                                             │
│   if [ -f "/etc/proxmox-sleep.conf" ]; then                │
│       # shellcheck source=/dev/null                        │
│       source "/etc/proxmox-sleep.conf"                     │
│   fi                                                       │
│                                                             │
│   # Environment overrides (already in environment)         │
│   VMID="${VMID:-100}"                                      │
│   IDLE_THRESHOLD_MINUTES="${IDLE_THRESHOLD_MINUTES:-15}"   │
│   ...                                                      │
└─────────────────────────────────────────────────────────────┘
```

### Proxmox API Communication

```
┌─────────────────┐                    ┌─────────────────┐
│  Idle Monitor   │                    │   Proxmox API   │
│  / Sleep Mgr    │                    │    (pvesh)      │
└────────┬────────┘                    └────────┬────────┘
         │                                      │
         │  pvesh get /nodes/{node}/qemu/{vmid}/status/current
         │─────────────────────────────────────>│
         │                                      │
         │  { "status": "running", "cpu": 0.05, ... }
         │<─────────────────────────────────────│
         │                                      │
         │  qm status {vmid}                    │
         │─────────────────────────────────────>│
         │                                      │
         │  "status: running"                   │
         │<─────────────────────────────────────│
```

### Guest Agent Communication

```
┌─────────────────┐                    ┌─────────────────┐
│   Host Script   │                    │  QEMU Guest     │
│                 │                    │  Agent (VM)     │
└────────┬────────┘                    └────────┬────────┘
         │                                      │
         │  qm guest exec $VMID -- powershell -Command "..."
         │─────────────────────────────────────>│
         │                                      │
         │  (PowerShell executes in VM)         │
         │                                      │
         │  { "out-data": "base64...", "exitcode": 0 }
         │<─────────────────────────────────────│
         │                                      │
         │  (Decode base64, parse result)       │
```

---

## State Management

### State Files

| File | Purpose | Lifecycle |
|------|---------|-----------|
| `/tmp/proxmox-sleep-manager.state` | VM state before sleep | Created pre-sleep, read post-wake, deleted after use |
| `/tmp/proxmox-idle-monitor.state` | Idle timer start timestamp | Created when idle begins, deleted when active |
| `/tmp/proxmox-idle-monitor.wake` | Last wake timestamp | Created post-wake, used for grace period |

### State Transitions

```
                        ┌─────────────┐
                        │   ACTIVE    │
                        │  (Normal)   │
                        └──────┬──────┘
                               │
                    Activity detected
                               │
              ┌────────────────┴────────────────┐
              │                                 │
              ▼                                 │
     ┌─────────────────┐                        │
     │  IDLE_TRACKING  │                        │
     │  (Timer active) │                        │
     │                 │                        │
     │  state file:    │                        │
     │  timestamp      │                        │
     └────────┬────────┘                        │
              │                                 │
    Threshold reached                 Activity detected
              │                                 │
              ▼                                 │
     ┌─────────────────┐                        │
     │   TRIGGERING    │────────────────────────┘
     │    SLEEP        │
     └────────┬────────┘
              │
              ▼
     ┌─────────────────┐
     │  PRE_SLEEP      │
     │  (Hibernating)  │
     │                 │
     │  state file:    │
     │  "hibernated"   │
     └────────┬────────┘
              │
              ▼
     ┌─────────────────┐
     │   SLEEPING      │
     │  (Host in S3)   │
     └────────┬────────┘
              │
         Wake event
              │
              ▼
     ┌─────────────────┐
     │  POST_WAKE      │
     │  (Resuming VM)  │
     │                 │
     │  wake file:     │
     │  timestamp      │
     └────────┬────────┘
              │
              ▼
     ┌─────────────────┐
     │  GRACE_PERIOD   │
     │  (60s cooldown) │
     └────────┬────────┘
              │
              ▼
        (Back to ACTIVE)
```

### Robustness Mechanisms

1. **Stale State Detection**: If wake file is newer than idle state file, idle state is considered stale and reset.

2. **Negative Duration Guard**: Clock adjustments (NTP, manual) can cause negative durations; these are clamped to 0.

3. **Consecutive Stop Checks**: Requires 2 consecutive "stopped" readings before confirming hibernation complete (prevents race conditions).

4. **Grace Period**: Prevents immediate re-sleep after wake (user might not have interacted yet).

---

## Configuration System

### Configuration File Format

```bash
# /etc/proxmox-sleep.conf

# VM Configuration
VMID=100
VM_NAME="windows"

# Idle Detection
IDLE_THRESHOLD_MINUTES=15    # 0 = disable idle monitor
CHECK_INTERVAL=60            # Seconds between polls
CPU_IDLE_THRESHOLD=15        # VM CPU % threshold
GPU_IDLE_THRESHOLD=10        # GPU % threshold
GPU_VENDOR=auto              # nvidia, amd, or auto

# Activity Detection
CHECK_SSH_SESSIONS=1
GAMING_PROCESSES="steam.exe,epicgameslauncher.exe,origin.exe"
HOST_BLOCKING_PROCESSES="unattended-upgrade"
HOST_BLOCKING_UNITS="apt-daily.service,apt-daily-upgrade.service"
CHECK_SLEEP_INHIBITORS=1

# Timing
HIBERNATE_TIMEOUT=300        # Max wait for hibernation
WAKE_DELAY=5                 # Delay before starting VM
WAKE_GRACE_PERIOD=60         # Delay before allowing re-sleep

# Logging
SLEEP_MANAGER_LOG="/var/log/proxmox-sleep-manager.log"
IDLE_MONITOR_LOG="/var/log/proxmox-idle-monitor.log"
DEBUG=0
```

### Configuration Validation

Scripts validate configuration at startup:

```bash
validate_config() {
    # Ensure VMID is set and numeric
    if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
        die "VMID must be a positive integer"
    fi

    # Ensure VM exists
    if ! qm status "$VMID" &>/dev/null; then
        die "VM $VMID does not exist"
    fi

    # Validate thresholds
    if [[ "$IDLE_THRESHOLD_MINUTES" -lt 0 ]]; then
        die "IDLE_THRESHOLD_MINUTES cannot be negative"
    fi
}
```

---

## Error Handling

### Exit Codes

Following sysexits.h conventions:

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | EX_OK | Success |
| 64 | EX_USAGE | Command line usage error |
| 65 | EX_DATAERR | Data format error |
| 69 | EX_UNAVAILABLE | Service unavailable |
| 70 | EX_SOFTWARE | Internal software error |
| 78 | EX_CONFIG | Configuration error |

### Error Recovery Strategies

| Scenario | Strategy |
|----------|----------|
| Guest agent unresponsive | Log warning, attempt hibernation anyway |
| Hibernation timeout | Log error, allow sleep anyway (VM may be in undefined state) |
| VM doesn't exist | Exit successfully (nothing to manage) |
| Config file missing | Use defaults, log warning |
| State file corrupted | Reset to default state, continue |

### Logging Strategy

```bash
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Always log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Also log to systemd journal
    logger -t "proxmox-sleep-manager" -p "daemon.$level" "$message"

    # Debug messages only if DEBUG=1
    if [[ "$level" == "DEBUG" && "$DEBUG" != "1" ]]; then
        return
    fi
}
```

---

## Security Considerations

### Trust Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│                    Proxmox Host (Root)                      │
│                                                             │
│  Scripts run as root via systemd                            │
│  • Full system access                                       │
│  • Can execute any qm/pvesh command                         │
│                                                             │
│    ┌─────────────────────────────────────────────────────┐  │
│    │              QEMU Guest Agent Boundary              │  │
│    │                                                     │  │
│    │  Commands sent to VM via guest agent                │  │
│    │  • Limited to what guest agent allows               │  │
│    │  • VM can't affect host beyond responses            │  │
│    │                                                     │  │
│    │    ┌─────────────────────────────────────────────┐  │  │
│    │    │           Windows VM                        │  │  │
│    │    │                                             │  │  │
│    │    │  Idle helper runs as logged-in user         │  │  │
│    │    │  • Can only read input device idle time     │  │  │
│    │    │  • Writes to ProgramData (world-readable)   │  │  │
│    │    └─────────────────────────────────────────────┘  │  │
│    └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Security Properties

1. **No Network Exposure**: All communication is local (QEMU guest agent socket)
2. **No Credential Storage**: Uses existing Proxmox authentication
3. **No Privilege Escalation**: Already runs as root via systemd
4. **Package Signing**: GPG-signed packages for installation verification
5. **Config Protection**: Config file at `/etc/` with standard permissions

### Potential Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Malicious VM could return false idle data | VM is already trusted (user's own VM) |
| Config file tampering | Standard /etc/ permissions (root:root 644) |
| Log injection | Logs are append-only, rotated by logrotate |
| Race conditions during sleep | Consecutive check requirements, state files |

---

## Future Considerations

### Potential Enhancements

1. **Multi-VM Support**: Manage multiple VMs with different policies
2. **Network-Based Wake**: Integration with Wake-on-LAN triggers
3. **Scheduled Sleep Windows**: Time-based sleep policies (e.g., always sleep 2-6 AM)
4. **Power Monitoring**: Integration with smart plugs for actual power usage data
5. **Web UI**: Proxmox UI integration for status and configuration
6. **Metrics/Alerting**: Prometheus metrics for sleep/wake cycles

### Architecture Extensibility Points

```
┌─────────────────────────────────────────────────────────────┐
│                   Future Extension Points                    │
│                                                             │
│  1. Activity Check Plugins                                  │
│     └─ Add new check types without modifying core logic     │
│                                                             │
│  2. Pre/Post Hooks                                          │
│     └─ Custom scripts before hibernate / after wake         │
│                                                             │
│  3. Notification System                                     │
│     └─ Webhook/email on sleep/wake events                   │
│                                                             │
│  4. State Backend                                           │
│     └─ Replace file-based state with DB for multi-node      │
│                                                             │
│  5. Alternative Sleep Methods                               │
│     └─ Support QEMU savestate for non-GPU VMs               │
└─────────────────────────────────────────────────────────────┘
```

---

## Appendix: File Locations

| Path | Purpose |
|------|---------|
| `/usr/local/bin/proxmox-sleep-manager.sh` | Sleep manager script |
| `/usr/local/bin/proxmox-idle-monitor.sh` | Idle monitor script |
| `/etc/proxmox-sleep.conf` | Configuration file |
| `/etc/systemd/system/proxmox-sleep-manager.service` | Sleep manager unit |
| `/etc/systemd/system/proxmox-idle-monitor.service` | Idle monitor unit |
| `/etc/logrotate.d/proxmox-sleep` | Log rotation config |
| `/var/log/proxmox-sleep-manager.log` | Sleep manager log |
| `/var/log/proxmox-idle-monitor.log` | Idle monitor log |
| `/tmp/proxmox-sleep-manager.state` | VM state tracking |
| `/tmp/proxmox-idle-monitor.state` | Idle timer state |
| `/tmp/proxmox-idle-monitor.wake` | Wake timestamp |
