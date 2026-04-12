# Future Work: Agent Architecture and Cross-Platform Support

This document describes planned enhancements for the Proxmox Sleep Manager.

## Overview

The current implementation supports multiple VMs and LXC containers with per-instance idle detection and sleep actions. Host-side scripts query each instance directly (via QEMU guest agent or `pct exec`). This TODO describes further enhancements:

1. Delegate idle detection to in-VM/container agent processes
2. Support Linux and macOS guest VMs in addition to Windows

---

## 1. Agent-Based Architecture

### Current Limitation

The host idle monitor queries each VM/container directly for every check (CPU, GPU, user idle, power requests, gaming processes). This:
- Requires multiple guest agent calls per check cycle
- Has high latency for each query
- Duplicates logic between host scripts and in-VM helper

### Proposed Enhancement

Move all idle detection logic into in-VM/container agents. The host only needs to ask: "Are you idle?" and receive a simple yes/no response with optional metadata.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Proxmox Host                                  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    Idle Monitor (Host)                         │ │
│  │                                                                │ │
│  │  For each VM/CT:                                               │ │
│  │    query_instance_idle_status() ─────┐                         │ │
│  │                                      │                         │ │
│  │  Aggregate responses                 │                         │ │
│  │  Trigger sleep when all idle         │                         │ │
│  └──────────────────────────────────────┼─────────────────────────┘ │
│                                         │                            │
│                                         │ qm guest exec / pct exec  │
│                                         │                            │
│  ┌──────────────────────────────────────┼─────────────────────────┐ │
│  │  VM 100 (Windows)                    ▼                         │ │
│  │  ┌─────────────────────────────────────────────────────────┐   │ │
│  │  │            Tray Agent (proxmox-sleep-agent.exe)         │   │ │
│  │  │                                                         │   │ │
│  │  │  Checks (all performed locally):                        │   │ │
│  │  │  • Keyboard/mouse idle time (GetLastInputInfo)          │   │ │
│  │  │  • GPU usage (nvidia-smi / WMI perf counters)           │   │ │
│  │  │  • Power requests (powercfg /requests)                  │   │ │
│  │  │  • Gaming processes (process list scan)                 │   │ │
│  │  │                                                         │   │ │
│  │  │  Responds to queries:                                   │   │ │
│  │  │  • GET /status → {"idle": false, "reason": "gpu_active"}│   │ │
│  │  └─────────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  Container 200 (Linux)                                         │ │
│  │  ┌─────────────────────────────────────────────────────────┐   │ │
│  │  │            CLI Agent (proxmox-sleep-agent daemon)       │   │ │
│  │  │                                                         │   │ │
│  │  │  Checks: X11/Wayland idle, load average, processes      │   │ │
│  │  │  Responds via: pct exec or named pipe/socket            │   │ │
│  │  └─────────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### Agent Protocol

The agent should respond to queries in a simple JSON format:

```json
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
```

### Communication Methods

| Guest Type | Primary Method | Fallback |
|------------|---------------|----------|
| Windows VM | QEMU Guest Agent exec | N/A |
| Linux VM | QEMU Guest Agent exec | SSH |
| LXC Container | pct exec | N/A |
| macOS VM | SSH (guest agent not available) | N/A |

---

## 2. Cross-Platform Agent Support

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
- Responds via QEMU guest agent or pct exec

#### CLI Variant (Headless Linux)
- Runs as systemd service
- No idle detection for user input (headless = no user input)
- Tracks load average, network activity, active processes
- Responds via QEMU guest agent or pct exec

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

**Implementation**: Shell script or Swift

### macOS Considerations

- QEMU guest agent: Not officially supported on macOS
- Idle detection: `ioreg -c IOHIDSystem | grep HIDIdleTime` gives nanoseconds since last input
- Hibernation: macOS `pmset sleepnow` or `sudo shutdown -s now`
- Shutdown: `sudo shutdown -h now`

---

## 3. Implementation Phases

### Phase 1: Agent Protocol Design
- Define JSON protocol for agent communication
- Create host-side query functions
- Test with existing Windows helper (add protocol support)

### Phase 2: Windows Agent Enhancement
- Move all idle checks from host to Windows agent
- Add hibernate/shutdown command handlers
- Test end-to-end with new architecture

### Phase 3: Linux Agent
- Develop GUI variant for desktop Linux
- Develop CLI variant for headless Linux
- Package for common distributions

### Phase 4: macOS Agent
- Investigate QEMU guest agent viability
- Implement SSH-based communication
- Develop macOS agent with LaunchAgent integration

---

## 4. Open Questions

1. **Parallel vs Sequential Instance Operations**: When putting host to sleep, should VMs/containers be acted on in parallel or sequentially? Parallel is faster but may stress storage.

2. **Timeout Handling**: If one instance fails to stop, should we:
   - Cancel the sleep operation?
   - Continue with remaining instances and sleep anyway?
   - Make this configurable per-instance?

3. **Proxmox Cluster Support**: Should multiple nodes coordinate sleep decisions?

4. **Windows Agent Language**: Stay with PowerShell for easy modification, or compile to EXE for better performance and easier distribution?

---

## 5. Related Work

- Current Windows tray helper: `proxmox-idle-monitor.sh install-helper` functionality
- Existing idle checks in: `proxmox-idle-monitor.sh`
- Multi-instance architecture documented in: `docs/DESIGN.md`
