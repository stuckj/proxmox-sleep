# Proxmox Sleep Manager - Design Documentation

This document provides a comprehensive technical overview of the Proxmox Sleep Manager architecture, components, and design decisions.

## Table of Contents

- [Problem Statement](#problem-statement)
- [Solution Overview](#solution-overview)
- [Architecture](#architecture)
- [Instance Iteration Model](#instance-iteration-model)
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

Running Windows VMs and Linux containers with GPU passthrough on Proxmox hosts presents a significant power management challenge:

1. **Native S3 Sleep Limitations**: Hardware sleep (S3/S2idle) with GPU passthrough is unreliable because:
   - GPUs often lack proper Function Level Reset (FLR) support
   - PCIe device state doesn't survive host sleep/wake cycles
   - Resume can cause VM crashes, kernel panics, or ZFS corruption

2. **Power Consumption**: Leaving a powerful workstation running 24/7 wastes significant electricity when not in use.

3. **User Experience**: Users want their VMs and containers to "just work" when they return, similar to a laptop waking from sleep.

### Why Existing Solutions Fall Short

- **VM Suspend (QEMU savestate)**: Doesn't release GPU resources, host still can't sleep
- **VM Shutdown**: Loses session state, requires full boot on wake
- **Native S3 with GPU**: High failure rate, data corruption risk
- **Manual hibernation**: Requires user intervention, defeats automation purpose

---

## Solution Overview

### Core Approach

Use **Windows hibernation** for VMs and **graceful shutdown** for LXC containers as state preservation mechanisms, decoupled from host sleep:

1. **Before host sleep** (default): Hibernate Windows VMs (saves RAM to disk, releases all hardware) and shut down LXC containers
2. **Host sleeps**: In the typical path, after all managed VMs/containers have been stopped, the host enters a safe S3/S2idle state
3. **Host wakes**: Start previously stopped VMs (which resume from hibernation) and start previously stopped containers

Individual instances can opt out of being stopped by setting `SLEEP_ACTION=keep_running` or `SLEEP_ACTION=ignore`, or by setting `MONITOR=0` to exclude them from idle detection entirely. In practice, VMs with PCI passthrough (e.g., a passthrough GPU) generally **must** be stopped before host sleep — leaving them running is usually unsafe and can crash the host on wake.

### Two-Component Design

| Component | Role | Execution Model |
|-----------|------|-----------------|
| **Sleep Manager** | Orchestrates VM hibernation/shutdown and container shutdown/resume around host sleep | Systemd hook (oneshot) |
| **Idle Monitor** | Detects inactivity across all instances and triggers host sleep | Systemd daemon (long-running) |

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
│  │  │ manager.service     │    │ (Polls every CHECK_INTERVAL)     │   │   │
│  │  │ (Type=oneshot)      │    │                                  │   │   │
│  │  └──────────┬──────────┘    └───────────────┬──────────────────┘   │   │
│  └─────────────┼───────────────────────────────┼───────────────────────┘   │
│                │                               │                           │
│      ┌─────────┴─────────┐          ┌──────────┴──────────┐               │
│      ▼                   ▼          ▼                     ▼               │
│  ┌────────────┐   ┌────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │ VM Control │   │ CT Control │  │ VM Activity  │  │ CT Activity  │    │
│  │ qm start/  │   │ pct start/ │  │ Checks       │  │ Checks       │    │
│  │ shutdown/  │   │ shutdown/  │  │ (guest agent)│  │ (pct exec)   │    │
│  │ guest exec │   │ stop       │  │              │  │              │    │
│  └─────┬──────┘   └─────┬──────┘  └──────┬───────┘  └──────┬───────┘    │
│        │                │               │                  │             │
│        ▼                ▼               ▼                  ▼             │
│  ┌──────────────────┐  ┌──────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ Windows VM (QEMU)│  │ LXC CT   │  │ Host Activity│  │ Host GPU     │ │
│  │ • Guest Agent    │  │ • ps     │  │ • SSH, procs │  │ • nvidia-smi │ │
│  │ • Idle Helper    │  │ • gaming │  │ • units      │  │ (for CTs)    │ │
│  │ • GPU (in-guest) │  │          │  │ • inhibitors │  │              │ │
│  └──────────────────┘  └──────────┘  └──────────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Instance Iteration Model

The system manages an arbitrary number of VMs and LXC containers, each configured independently.

### Configuration

Instances are declared via two space-separated ID lists:

```bash
VM_IDS="100 101"
CONTAINER_IDS="200 201"
```

Per-instance settings use the naming convention `VM_<id>_<SETTING>` or `CONTAINER_<id>_<SETTING>` and are read via bash indirect expansion (`${!var}`).

### Legacy Compatibility

If `VM_IDS` is empty but the old `VMID=` variable is present, a **legacy shim** function (`hydrate_legacy_config`) synthesizes a single VM entry at startup. This means existing configs from before container support was added continue to work without modification, and remain so when the user adds `CONTAINER_IDS`.

### Sleep Decision

The host sleeps only when **all** of the following are true:
1. All host-level checks pass (SSH, blocking processes, systemd units, sleep inhibitors)
2. Every monitored VM is idle (or not running)
3. Every monitored container is idle (or not running)

### Pre-Sleep Actions

Each instance has a configurable `SLEEP_ACTION`:

| Action | VMs | Containers | Behavior |
|--------|-----|------------|----------|
| `hibernate` | Yes | No* | Send `shutdown /h` via QEMU guest agent |
| `shutdown` | Yes | Yes | `qm shutdown` / `pct shutdown` with timeout, force-stop on failure |
| `keep_running` | Yes | Yes | Leave running, record state only |
| `ignore` | Yes | Yes | Don't touch at all |

\* If `hibernate` is set for a container it is treated as `shutdown` with a warning.

### State File

Pre-sleep records one line per instance in `/run/proxmox-sleep/sleep-manager.state`:

```
vm_100=hibernated
ct_200=shutdown
vm_101=not_running
```

Post-wake reads the file and starts any instance whose state is `hibernated`, `shutdown`, or `was_shutdown`, unless `RESUME_ON_WAKE` is turned off for it. Instances with `not_running`, `kept_running`, or `ignored` are left as-is.

---

## Component Details

### Sleep Manager (`proxmox-sleep-manager.sh`)

**Purpose**: Orchestrate VM hibernation, VM/container shutdown, and resume around host sleep.

**Execution Context**: Runs as a systemd oneshot service, triggered by sleep.target.

#### Key Functions

| Function | Description |
|----------|-------------|
| `pre_sleep()` | Iterates `VM_IDS` and `CONTAINER_IDS`, executes per-instance sleep action |
| `post_wake()` | Reads state file, resumes instances where appropriate |
| `hibernate_vm(id)` | Send `shutdown /h` via guest agent, poll until stopped |
| `shutdown_vm(id)` | `qm shutdown` with timeout, force-stop fallback |
| `shutdown_ct(id)` | `pct shutdown` with timeout, `pct stop` fallback |
| `resume_instance(kind, id)` | `qm start` or `pct start` with race-condition handling |

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

### Idle Monitor (`proxmox-idle-monitor.sh`)

**Purpose**: Continuously monitor system activity and trigger host sleep when idle threshold is reached.

**Execution Context**: Runs as a long-running systemd daemon.

#### Idle Detection Hierarchy

```
                        ┌─────────────────┐
                        │  is_system_idle()│
                        └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
     ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
     │ Host-Level     │ │ Per-VM Checks  │ │ Per-CT Checks  │
     │ (always)       │ │ (if monitored  │ │ (if monitored  │
     │                │ │  and running)  │ │  and running)  │
     └───────┬────────┘ └───────┬────────┘ └───────┬────────┘
             │                  │                  │
    ┌────────┴────┐    ┌───────┴────────┐  ┌──────┴──────┐
    │ SSH         │    │ VM GPU (guest) │  │ CT GPU (host│
    │ Host procs  │    │ VM CPU (pvesh) │  │  nvidia-smi)│
    │ Host units  │    │ User idle time │  │ CT CPU      │
    │ Inhibitors  │    │ Gaming procs   │  │ Gaming procs│
    └─────────────┘    │ Power requests │  └─────────────┘
                       └────────────────┘
```

#### GPU Check Architecture

- **VM GPU**: Queried *inside* the Windows guest via QEMU guest agent (nvidia-smi, AMD perf counters). This is necessary because the host-side GPU driver is replaced by vfio-pci during passthrough — `nvidia-smi` on the host sees no device while the VM is running.

- **Container GPU**: Queried on the host via `nvidia-smi`. When the GPU is bound to vfio-pci (VM running), `nvidia-smi` returns an error, which is treated as `-1` (no signal, not active) — the correct graceful degradation.

---

## Data Flow

### Configuration Loading

```
Priority (highest to lowest):
1. Environment variables
2. /etc/proxmox-sleep.conf (sourced)
3. Built-in defaults

After sourcing:
  hydrate_legacy_config() runs — if only VMID= is set,
  synthesizes VM_IDS and VM_<id>_* variables
```

### Proxmox API Communication

```
Host Script ──> pvesh get /nodes/{node}/qemu/{vmid}/status/current   (VM CPU)
            ──> pvesh get /nodes/{node}/lxc/{ctid}/status/current    (CT CPU)
            ──> qm status {vmid}          (VM running check)
            ──> pct status {ctid}         (CT running check)
            ──> qm guest exec {vmid} ...  (Windows queries)
            ──> pct exec {ctid} ...       (Container queries)
```

---

## State Management

### State Files

| File | Purpose | Lifecycle |
|------|---------|-----------|
| `/run/proxmox-sleep/sleep-manager.state` | Instance states before sleep (key=value, one per line) | Created pre-sleep, read post-wake, cleared once everything is back up |
| `/run/proxmox-sleep/idle-monitor.state` | Idle timer start timestamp | Created when idle begins, deleted when active |
| `/run/proxmox-sleep/idle-monitor.wake` | Last wake timestamp | Created post-wake, used for grace period |

### State Transitions

```
ACTIVE (monitoring) ──idle──> IDLE_TRACKING (timer) ──threshold──> TRIGGERING_SLEEP
     ▲                              │                                    │
     │                         activity                           systemctl suspend
     └──────────────────────────────┘                                    │
                                                                         ▼
                                                                    PRE_SLEEP
                                                               (hibernate VMs,
                                                                shutdown CTs,
                                                                write state file)
                                                                         │
                                                                         ▼
                                                                    SLEEPING (S3)
                                                                         │
                                                                    wake event
                                                                         │
                                                                         ▼
                                                                    POST_WAKE
                                                               (read state file,
                                                                resume instances,
                                                                record wake time)
                                                                         │
                                                                         ▼
                                                                   GRACE_PERIOD
                                                                    (60s cooldown)
                                                                         │
                                                                         ▼
                                                                   Back to ACTIVE
```

### Robustness Mechanisms

1. **Stale State Detection**: If wake file is newer than idle state file, idle state is reset.
2. **Negative Duration Guard**: Clock adjustments are detected and idle state is reset.
3. **Consecutive Stop Checks**: Requires 3 consecutive "stopped" readings before confirming VM hibernation.
4. **Grace Period**: Prevents immediate re-sleep after wake.
5. **Force-Stop Fallback**: If graceful shutdown times out, `qm stop` / `pct stop` is used.

---

## Configuration System

### Per-Instance Configuration

```bash
# VM settings
VM_<id>_NAME="display name"
VM_<id>_MONITOR=1|0
VM_<id>_SLEEP_ACTION=hibernate|shutdown|keep_running|ignore
VM_<id>_RESUME_ON_WAKE=1|0
VM_<id>_GAMING_PROCESSES="proc1.exe,proc2.exe"
VM_<id>_CHECK_POWER_REQUESTS=1|0
VM_<id>_CHECK_USER_IDLE=1|0
VM_<id>_CPU_IDLE_THRESHOLD=15        # optional override
VM_<id>_GPU_IDLE_THRESHOLD=10        # optional override

# Container settings
CONTAINER_<id>_NAME="display name"
CONTAINER_<id>_MONITOR=1|0
CONTAINER_<id>_SLEEP_ACTION=shutdown|keep_running|ignore
CONTAINER_<id>_RESUME_ON_WAKE=1|0
CONTAINER_<id>_GAMING_PROCESSES="steam,wine,gamescope"
CONTAINER_<id>_CPU_IDLE_THRESHOLD=15  # optional override
CONTAINER_<id>_GPU_IDLE_THRESHOLD=10  # optional override
```

### Configuration Validation

Validation belongs to the idle monitor: it is the long-running daemon, so a bad
config there is worth refusing to start over. `proxmox-sleep-manager.sh` runs as
a systemd sleep hook, re-reads the config on every invocation and validates
nothing — it must act on whatever it finds, so unrecognised values fall back to
the safe default rather than aborting the suspend.

`proxmox-idle-monitor.sh start` checks the instances exist and every setting is
in range before entering its loop; `validate_config` is the authority on the
rules. Invalid config exits with `EX_CONFIG` (78), which the unit's
`RestartPreventExitStatus` treats as terminal rather than restarting into the
same failure.

---

## Error Handling

### Exit Codes

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | EX_OK | Success |
| 78 | EX_CONFIG | Configuration error (prevents restart) |

### Error Recovery Strategies

| Scenario | Strategy |
|----------|----------|
| Guest agent unresponsive | Fall back to `qm shutdown` |
| Hibernation timeout | Graceful `qm shutdown`, recorded as `shutdown`; force-stop and `was_shutdown` only if that also fails |
| Container shutdown timeout | `pct stop` (force), record `was_shutdown` |
| nvidia-smi unavailable (host) | Return -1 (no signal), don't block sleep |
| `pct exec` fails | Return -1 / not found, don't block sleep |
| VM doesn't exist | Exit with EX_CONFIG at startup |
| State file corrupted | Reset to default state, continue |

---

## Security Considerations

### Trust Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│                    Proxmox Host (Root)                      │
│                                                             │
│  Scripts run as root via systemd                            │
│  • Full system access (qm, pct, pvesh)                     │
│                                                             │
│    ┌─────────────────────────────────────────────────────┐  │
│    │              QEMU Guest Agent / pct exec             │  │
│    │                                                     │  │
│    │  Commands sent to VMs via guest agent                │  │
│    │  Commands sent to containers via pct exec            │  │
│    │  • Limited to what each mechanism allows             │  │
│    └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Security Properties

1. **No Network Exposure**: All communication is local (guest agent socket, pct exec)
2. **No Credential Storage**: Uses existing Proxmox authentication
3. **Package Signing**: GPG-signed packages for installation verification
4. **Config Protection**: Config file at `/etc/` with standard permissions

---

## Future Considerations

Planned work is tracked in [GitHub issues](https://github.com/stuckj/proxmox-sleep/issues).

1. **Agent-Based Architecture** ([#11](https://github.com/stuckj/proxmox-sleep/issues/11)):
   - Delegate idle detection to in-VM/container agent processes
   - Cross-platform agents: Windows (enhance existing), Linux (GUI + CLI), macOS (via SSH)

2. **Network-Based Wake**: Integration with Wake-on-LAN triggers
3. **Scheduled Sleep Windows**: Time-based sleep policies
4. **Power Monitoring**: Integration with smart plugs
5. **Web UI**: Proxmox UI integration
6. **Metrics/Alerting**: Prometheus metrics for sleep/wake cycles

---

## Appendix: File Locations

| Path | Purpose |
|------|---------|
| `/usr/local/bin/proxmox-sleep-manager.sh` | Sleep manager script |
| `/usr/local/bin/proxmox-idle-monitor.sh` | Idle monitor script |
| `/etc/proxmox-sleep.conf` | Configuration file |
| `/lib/systemd/system/proxmox-sleep-manager.service` | Sleep manager unit |
| `/lib/systemd/system/proxmox-idle-monitor.service` | Idle monitor unit |
| `/etc/logrotate.d/proxmox-sleep` | Log rotation config |
| `/var/log/proxmox-sleep-manager.log` | Sleep manager log |
| `/var/log/proxmox-idle-monitor.log` | Idle monitor log |
| `/run/proxmox-sleep/sleep-manager.state` | Instance state tracking (key=value) |
| `/run/proxmox-sleep/idle-monitor.state` | Idle timer state |
| `/run/proxmox-sleep/idle-monitor.wake` | Wake timestamp |
