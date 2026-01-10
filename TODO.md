# Future Work: Multi-VM and Cross-Platform Agent Architecture

This document describes planned enhancements for the Proxmox Sleep Manager.

## Overview

The current implementation supports a single Windows VM with idle detection performed by the host querying the VM via guest agent. This TODO describes extending the architecture to:

1. Support multiple VMs with per-VM sleep behavior configuration
2. Delegate idle detection to in-VM agent processes
3. Support Linux and macOS guest VMs in addition to Windows

---

## 1. Multi-VM Support

### Current Limitation

The system currently monitors a single VM (`VMID` in config) and bases host sleep decisions on that one VM's state.

### Proposed Enhancement

Monitor multiple VMs simultaneously. The host should only sleep when **all** monitored VMs indicate they are idle (or are configured to not block sleep).

### Per-VM Configuration

Each VM should be configurable with:

| Setting | Options | Description |
|---------|---------|-------------|
| `monitor` | `true/false` | Whether this VM participates in idle detection |
| `sleep_action` | `hibernate`, `shutdown`, `keep_running`, `ignore` | What to do with this VM when host sleeps |
| `resume_on_wake` | `true/false` | Whether to start this VM when host wakes |
| `idle_timeout` | minutes | Per-VM idle threshold (optional, can use global default) |

#### Example Configuration

```bash
# /etc/proxmox-sleep.conf

# Global settings
IDLE_THRESHOLD_MINUTES=15

# VM-specific settings (new format)
# Format: VM_<VMID>_<SETTING>=value

# Windows gaming VM - hibernate when host sleeps, resume on wake
VM_100_MONITOR=1
VM_100_SLEEP_ACTION=hibernate
VM_100_RESUME_ON_WAKE=1

# Linux server VM - keep running, don't block sleep
VM_101_MONITOR=0
VM_101_SLEEP_ACTION=keep_running
VM_101_RESUME_ON_WAKE=0

# Development VM - shutdown when host sleeps, resume on wake
VM_102_MONITOR=1
VM_102_SLEEP_ACTION=shutdown
VM_102_RESUME_ON_WAKE=1

# Appliance VM - ignore entirely (doesn't affect sleep decisions)
VM_103_MONITOR=0
VM_103_SLEEP_ACTION=ignore
VM_103_RESUME_ON_WAKE=0
```

### Sleep Decision Logic

```
can_host_sleep():
    for each configured VM:
        if VM.monitor == true:
            if not VM.is_idle():
                return false  # At least one monitored VM is active
    return true  # All monitored VMs are idle

pre_sleep():
    for each configured VM (in parallel or sequenced):
        match VM.sleep_action:
            hibernate: send hibernate command to VM, wait for completion
            shutdown: send shutdown command to VM, wait for completion
            keep_running: do nothing
            ignore: do nothing

post_wake():
    for each configured VM where resume_on_wake == true:
        start VM
```

---

## 2. Agent-Based Architecture

### Current Limitation

The host idle monitor queries the VM directly using the QEMU guest agent for each check (CPU, GPU, user idle, power requests, gaming processes). This:
- Requires multiple guest agent calls per check cycle
- Has high latency for each query
- Duplicates logic between host scripts and in-VM helper

### Proposed Enhancement

Move all idle detection logic into the in-VM agent (tray process or daemon). The host only needs to ask: "Are you idle?" and receive a simple yes/no response with optional metadata.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Proxmox Host                                  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    Idle Monitor (Host)                         │ │
│  │                                                                │ │
│  │  For each VM:                                                  │ │
│  │    query_vm_idle_status() ─────┐                               │ │
│  │                                │                               │ │
│  │  Aggregate responses           │                               │ │
│  │  Trigger sleep when all idle   │                               │ │
│  └────────────────────────────────┼───────────────────────────────┘ │
│                                   │                                  │
│                                   │ qm guest exec / SSH              │
│                                   │                                  │
│  ┌────────────────────────────────┼───────────────────────────────┐ │
│  │  VM 100 (Windows)              ▼                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐   │ │
│  │  │            Tray Agent (proxmox-sleep-agent.exe)         │   │ │
│  │  │                                                         │   │ │
│  │  │  Checks (all performed locally):                        │   │ │
│  │  │  • Keyboard/mouse idle time (GetLastInputInfo)          │   │ │
│  │  │  • GPU usage (nvidia-smi / WMI perf counters)           │   │ │
│  │  │  • Power requests (powercfg /requests)                  │   │ │
│  │  │  • Gaming processes (process list scan)                 │   │ │
│  │  │  • Custom checks (configurable)                         │   │ │
│  │  │                                                         │   │ │
│  │  │  Responds to queries:                                   │   │ │
│  │  │  • GET /status → {"idle": false, "reason": "gpu_active"}│   │ │
│  │  │                                                         │   │ │
│  │  │  Handles commands:                                      │   │ │
│  │  │  • POST /hibernate → triggers shutdown /h               │   │ │
│  │  │  • POST /shutdown → triggers shutdown /s                │   │ │
│  │  └─────────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  VM 101 (Linux)                                                │ │
│  │  ┌─────────────────────────────────────────────────────────┐   │ │
│  │  │            CLI Agent (proxmox-sleep-agent daemon)       │   │ │
│  │  │                                                         │   │ │
│  │  │  Checks: X11/Wayland idle, load average, processes      │   │ │
│  │  │  Responds via: guest agent exec or named pipe/socket    │   │ │
│  │  └─────────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### Agent Protocol

The agent should respond to queries in a simple JSON format:

```json
// Query: "status"
// Response:
{
  "idle": false,
  "idle_seconds": 42,
  "reason": "gpu_active",
  "details": {
    "user_idle_seconds": 900,
    "gpu_percent": 85,
    "power_requests": [],
    "active_processes": ["game.exe"]
  }
}

// Query: "hibernate"
// Response:
{
  "success": true,
  "message": "Hibernation initiated"
}

// Query: "shutdown"
// Response:
{
  "success": true,
  "message": "Shutdown initiated"
}
```

### Communication Methods

| Guest OS | Primary Method | Fallback |
|----------|---------------|----------|
| Windows | QEMU Guest Agent exec | N/A |
| Linux | QEMU Guest Agent exec | SSH |
| macOS | SSH (guest agent not available) | N/A |

---

## 3. Cross-Platform Agent Support

### Windows Agent (Enhance Existing)

The current Windows tray helper already exists. Enhance it to:
- Perform all idle checks locally (move from host scripts)
- Respond to status queries via stdout when invoked by guest agent
- Handle hibernate/shutdown commands
- Keep the tray icon functionality for user visibility

**Implementation**: PowerShell or compiled executable

### Linux Agent

Two variants needed:

#### GUI Variant (Desktop Linux)
- System tray icon (using libappindicator or similar)
- X11/Wayland idle detection (xprintidle, dbus IdleTime, or similar)
- GPU detection (nvidia-smi, AMD rocm-smi)
- Responds via QEMU guest agent

#### CLI Variant (Headless Linux)
- Runs as systemd service
- No idle detection for user input (headless = no user input)
- Tracks load average, network activity, active processes
- Responds via QEMU guest agent

**Implementation**: Shell script + Python, or Go for single binary

### macOS Agent

macOS does not have QEMU guest agent support. Alternative approaches:

#### Option 1: SSH-Based Communication (Recommended)
- Host connects via SSH to query agent
- Requires SSH server enabled on macOS guest
- Agent runs as LaunchAgent (user session) or LaunchDaemon (system)
- Uses `ioreg` for idle time detection
- Uses `powermetrics` or vendor tools for GPU

#### Option 2: Shared Folder Communication
- Agent writes status to a file on a shared folder (virtio-fs or 9p)
- Host reads the status file
- Less elegant but doesn't require SSH

**Implementation**: Shell script or Swift

### macOS Considerations

- QEMU guest agent: Not officially supported on macOS
  - May work with qemu-guest-agent from homebrew, but unreliable
  - SSH is more reliable for macOS guests
- Idle detection:
  - `ioreg -c IOHIDSystem | grep HIDIdleTime` gives nanoseconds since last input
  - Requires accessibility permissions for some methods
- Hibernation: macOS `pmset sleepnow` or `sudo shutdown -s now`
- Shutdown: `sudo shutdown -h now`

---

## 4. Implementation Phases

### Phase 1: Multi-VM Configuration
- Extend config file format to support multiple VMs
- Update sleep manager to iterate over configured VMs
- Update idle monitor to check all monitored VMs
- Maintain backward compatibility with single-VM config

### Phase 2: Agent Protocol Design
- Define JSON protocol for agent communication
- Create host-side query functions
- Test with existing Windows helper (add protocol support)

### Phase 3: Windows Agent Enhancement
- Move all idle checks from host to Windows agent
- Add hibernate/shutdown command handlers
- Test end-to-end with new architecture

### Phase 4: Linux Agent
- Develop GUI variant for desktop Linux
- Develop CLI variant for headless Linux
- Package for common distributions

### Phase 5: macOS Agent
- Investigate QEMU guest agent viability
- Implement SSH-based communication
- Develop macOS agent with LaunchAgent integration

---

## 5. Open Questions

1. **Parallel vs Sequential VM Operations**: When putting host to sleep, should VMs be hibernated/shutdown in parallel or sequentially? Parallel is faster but may stress storage.

2. **Timeout Handling**: If one VM fails to hibernate, should we:
   - Cancel the sleep operation?
   - Continue with remaining VMs and sleep anyway?
   - Make this configurable per-VM?

3. **LXC Container Support**: Should this extend to LXC containers as well as VMs?

4. **Proxmox Cluster Support**: Should multiple nodes coordinate sleep decisions?

5. **Windows Agent Language**: Stay with PowerShell for easy modification, or compile to EXE for better performance and easier distribution?

---

## 6. Related Work

- Current Windows tray helper: `proxmox-idle-monitor.sh install-helper` functionality
- Existing idle checks in: `proxmox-idle-monitor.sh`
- Current single-VM architecture documented in: `docs/DESIGN.md`
