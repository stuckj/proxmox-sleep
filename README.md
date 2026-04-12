# Proxmox Sleep Manager

Automated power management for Proxmox hosts with Windows VMs, LXC containers, and GPU passthrough.

## The Problem

- Gaming desktop runs Proxmox with Windows 11 VM + GPU passthrough
- May also run Linux LXC containers (e.g., Steam gaming container)
- Machine draws ~150W idle, but only used a few hours per week
- Native sleep (S3) with GPU passthrough often causes issues (crashes, ZFS corruption)
- Windows VM suspend via QEMU doesn't survive host sleep
- Want the machine to auto-sleep when idle

## The Solution

This project provides two components:

1. **Sleep Manager**: Automatically hibernates VMs and shuts down containers before host sleep, and resumes them after wake
2. **Idle Monitor**: Detects when the system is truly idle and triggers sleep

### How It Works

```
Host Going to Sleep:
┌─────────────┐    ┌──────────────────┐    ┌─────────────┐    ┌────────────┐
│ systemctl   │───>│ sleep-manager    │───>│ VMs hibernate│───>│ Host       │
│ suspend     │    │ (pre-sleep hook) │    │ CTs shutdown │    │ sleeps     │
└─────────────┘    └──────────────────┘    └─────────────┘    └────────────┘

Host Waking Up:
┌─────────────┐    ┌──────────────────┐    ┌─────────────┐
│ Host wakes  │───>│ sleep-manager    │───>│ VMs start   │
│             │    │ (post-wake hook) │    │ CTs start   │
└─────────────┘    └──────────────────┘    └─────────────┘
```

Windows hibernation writes RAM to disk; when the VM starts it resumes exactly where it left off. LXC containers are shut down cleanly and started fresh on wake.

## Requirements

- Proxmox VE (tested on 7.x and 8.x)
- For Windows VMs: QEMU Guest Agent installed, hibernation enabled
- For LXC containers: no special requirements
- GPU passthrough with NVIDIA or AMD graphics card (optional)

### Enabling Windows Hibernation

If hibernation is disabled, enable it in an elevated PowerShell:
```powershell
powercfg /hibernate on
```

## Installation

### Option 1: Install from Repository (Recommended)

**Debian/Ubuntu/Proxmox (APT):**

```bash
# Add the GPG key
curl -fsSL https://stuckj.github.io/proxmox-sleep/gpg-key.asc | sudo gpg --dearmor -o /usr/share/keyrings/proxmox-sleep.gpg

# Add the repository
echo "deb [signed-by=/usr/share/keyrings/proxmox-sleep.gpg] https://stuckj.github.io/proxmox-sleep/apt stable main" | sudo tee /etc/apt/sources.list.d/proxmox-sleep.list

# Install
sudo apt update
sudo apt install proxmox-sleep
```

**RHEL/CentOS/Fedora (YUM/DNF):**

```bash
# Add the repository
sudo tee /etc/yum.repos.d/proxmox-sleep.repo << 'EOF'
[proxmox-sleep]
name=Proxmox Sleep Manager
baseurl=https://stuckj.github.io/proxmox-sleep/yum
enabled=1
gpgcheck=1
gpgkey=https://stuckj.github.io/proxmox-sleep/yum/gpg-key.asc
EOF

# Install
sudo dnf install proxmox-sleep
```

After installation, configure the package:

```bash
# Copy the example config
cp /usr/share/doc/proxmox-sleep/examples/proxmox-sleep.conf.example /etc/proxmox-sleep.conf

# Edit the config — set your VM IDs and/or container IDs
nano /etc/proxmox-sleep.conf

# Enable the idle monitor (sleep manager is already enabled)
systemctl enable --now proxmox-idle-monitor
```

### Option 2: Install from Source

```bash
# Clone the repository
git clone https://github.com/stuckj/proxmox-sleep.git
cd proxmox-sleep

# Run the installer (as root)
./install.sh
```

### Step 2: Install Windows Idle Helper (Required for VMs)

> **Important**: This step is required for proper keyboard/mouse idle detection with USB passthrough devices.

The QEMU guest agent runs as SYSTEM in Windows session 0, which cannot detect user input from USB passthrough keyboards and mice. A small helper application must run in your Windows user session to track idle time.

From the Proxmox host, run:
```bash
proxmox-idle-monitor.sh install-helper          # single VM
proxmox-idle-monitor.sh install-helper <VMID>    # specific VM
```

This installs a Windows scheduled task that:
- Runs automatically at user logon
- Displays a **system tray icon** showing current idle time (hover to see)
- Updates idle time every 10 seconds
- Can be exited by right-clicking the tray icon

## Usage

### Check Status
```bash
# Full status with idle tracking info
proxmox-idle-monitor.sh status

# Quick idle check (for testing)
proxmox-idle-monitor.sh check

# Detailed debug output
DEBUG=1 proxmox-idle-monitor.sh check

# Sleep manager status (shows all configured instances)
proxmox-sleep-manager.sh status
```

### Sleep Now (Manual Sleep)
```bash
# Immediately hibernate VMs, shut down containers, and sleep the host
proxmox-idle-monitor.sh sleep-now
```

### Other Operations
```bash
# Hibernate/shutdown all instances without sleeping host
proxmox-sleep-manager.sh hibernate

# Reset idle tracking (restart the countdown)
proxmox-idle-monitor.sh reset

# Reinstall Windows idle helper
proxmox-idle-monitor.sh install-helper [VMID]

# Wake: use Wake-on-LAN or press power button
```

### Logs
```bash
tail -f /var/log/proxmox-sleep-manager.log
tail -f /var/log/proxmox-idle-monitor.log
```

## Configuration

All settings are in `/etc/proxmox-sleep.conf`. The config supports multiple VMs and LXC containers with per-instance settings.

### Multi-Instance Format

```bash
# Global settings
IDLE_THRESHOLD_MINUTES=15
CHECK_INTERVAL=60
CPU_IDLE_THRESHOLD=15
GPU_IDLE_THRESHOLD=10
GPU_VENDOR=auto
CHECK_SSH_SESSIONS=1
HIBERNATE_TIMEOUT=300
SHUTDOWN_TIMEOUT=120
WAKE_DELAY=5
WAKE_GRACE_PERIOD=60

# Instance lists (space-separated Proxmox IDs)
VM_IDS="100"
CONTAINER_IDS="200"

# Per-VM settings
VM_100_NAME="windows-gaming"
VM_100_MONITOR=1
VM_100_SLEEP_ACTION=hibernate        # hibernate | shutdown | keep_running | ignore
VM_100_RESUME_ON_WAKE=1
VM_100_GAMING_PROCESSES="steam.exe,EpicGamesLauncher.exe,..."
VM_100_CHECK_POWER_REQUESTS=1
VM_100_CHECK_USER_IDLE=1

# Per-container settings
CONTAINER_200_NAME="steam-linux"
CONTAINER_200_MONITOR=1
CONTAINER_200_SLEEP_ACTION=shutdown  # shutdown | keep_running | ignore
CONTAINER_200_RESUME_ON_WAKE=1
CONTAINER_200_GAMING_PROCESSES="steam,steamwebhelper,wine,wineserver,proton,gamescope"
```

### Legacy Format (Backward Compatible)

If you set only `VMID=` and no `VM_IDS` / `CONTAINER_IDS`, the scripts automatically synthesize a single VM entry with legacy defaults. Existing configs continue to work without changes.

```bash
VMID=100
VM_NAME="windows"
GAMING_PROCESSES="steam.exe,EpicGamesLauncher.exe,..."
```

### Per-Instance Sleep Actions

| Action | VMs | Containers | Description |
|--------|-----|------------|-------------|
| `hibernate` | Yes | No* | Send `shutdown /h` via guest agent (Windows) |
| `shutdown` | Yes | Yes | Graceful shutdown via `qm shutdown` / `pct shutdown` |
| `keep_running` | Yes | Yes | Leave running through host sleep |
| `ignore` | Yes | Yes | Don't touch this instance |

\* If `hibernate` is set for a container, it is treated as `shutdown`.

See `proxmox-sleep.conf.example` for the complete reference.

Environment variables override config file settings, which override defaults.

## Idle Detection

The idle monitor checks multiple signals. **All** must indicate idle for the configured duration before triggering sleep.

### Host-Level Checks (Always Run)

| Check | Method | Notes |
|-------|--------|-------|
| SSH Sessions | Host `who` command | Optional, can disable |
| Host Blocking Processes | Host `pgrep` | e.g., unattended-upgrade |
| Host Blocking Units | `systemctl is-active` | apt-daily, apt-daily-upgrade |
| Sleep Inhibitors | `systemd-inhibit --list` | Media players, file transfers |

### VM Checks (Per Monitored VM, When Running)

| Check | Method | Notes |
|-------|--------|-------|
| VM CPU Usage | Proxmox API (`pvesh`) | Above threshold = active |
| GPU Usage | Guest Agent (nvidia-smi / perf counters) | Queried inside the VM |
| Windows Idle Time | Tray Helper App | Requires install-helper |
| Gaming Processes | Guest Agent (`Get-Process`) | Configurable list |
| Windows Power Requests | Guest Agent (`powercfg`) | Media players, downloads |

### Container Checks (Per Monitored Container, When Running)

| Check | Method | Notes |
|-------|--------|-------|
| Container CPU Usage | Proxmox API (`pvesh`) | Above threshold = active |
| GPU Usage | Host `nvidia-smi` | Gracefully degrades if unavailable |
| Gaming Processes | `pct exec` / `ps` | Configurable list |

### GPU Detection Notes

- **Windows VMs**: GPU is queried *inside* the VM via the QEMU guest agent, because the host-side GPU driver is replaced by vfio-pci during passthrough — `nvidia-smi` on the host sees nothing while the VM runs.
- **LXC Containers**: GPU is queried on the host via `nvidia-smi`. This naturally returns no data when the GPU is bound to vfio-pci (VM running), which is the correct behavior (container GPU check reports "no signal").

### Windows Idle Helper

The idle helper is essential for accurate keyboard/mouse detection. Without it:
- The system falls back to screensaver/lock detection only
- USB passthrough input won't be detected
- The system may sleep while you're actively using it

The helper runs silently with a system tray icon. If the icon is missing, reinstall:
```bash
proxmox-idle-monitor.sh install-helper
```

### Customizing Gaming Detection

Edit `/etc/proxmox-sleep.conf`:

```bash
# Windows VM gaming processes
VM_100_GAMING_PROCESSES="steam.exe,EpicGamesLauncher.exe,Cyberpunk2077.exe"

# Linux container gaming processes
CONTAINER_200_GAMING_PROCESSES="steam,steamwebhelper,wine,wineserver,gamescope"

# Disable gaming detection for an instance
VM_100_GAMING_PROCESSES=""
```

## Trying Native Sleep Instead

If you want to try making native S3 sleep work with your GPU passthrough (faster wake times), see `NATIVE_SLEEP_TROUBLESHOOTING.md`.

Native sleep is ideal but often problematic with NVIDIA GPUs. This hibernation-based approach is the reliable fallback.

## Troubleshooting

### "Guest agent not responsive"
- Check Windows Services → "QEMU Guest Agent" is running
- Test: `qm guest cmd <VMID> ping`

### VM doesn't resume from hibernation
- Check if hibernation works manually in Windows (Start → Power → Hibernate)
- If no Hibernate option: `powercfg /hibernate on` in admin PowerShell
- Check disk space (needs ~RAM size free for hiberfil.sys)

### Host crashes/reboots on sleep
- Your hardware may not support S3 sleep well
- Try S2idle instead: `echo s2idle > /sys/power/mem_sleep`
- Check BIOS for sleep-related settings

### Auto-sleep not triggering
```bash
# Debug mode shows all checks
DEBUG=1 proxmox-idle-monitor.sh check
```

### Windows Idle Time shows -1 or 99999
The Windows idle helper isn't running or isn't installed:
```bash
proxmox-idle-monitor.sh install-helper
```

Then log out and back in to Windows, or check Task Scheduler for "ProxmoxIdleHelper".

### Container gaming processes not detected
- Test manually: `pct exec <CTID> -- ps -eo comm=`
- Ensure the process names in `CONTAINER_<id>_GAMING_PROCESSES` match the output

### GPU usage not detected
```bash
# Test NVIDIA detection inside VM
qm guest exec <VMID> -- cmd /c "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits"

# Test host-side nvidia-smi (for containers)
nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits
```

## Uninstalling

### If installed from repository or package:

```bash
# Debian/Ubuntu/Proxmox:
sudo apt remove proxmox-sleep
# Optionally remove the repository:
sudo rm /etc/apt/sources.list.d/proxmox-sleep.list
sudo rm /usr/share/keyrings/proxmox-sleep.gpg

# RHEL/CentOS/Fedora:
sudo dnf remove proxmox-sleep
# Optionally remove the repository:
sudo rm /etc/yum.repos.d/proxmox-sleep.repo
```

### If installed from source:

```bash
./uninstall.sh
```

The config file (`/etc/proxmox-sleep.conf`) and log files are preserved after uninstall.

## Contributing

Contributions welcome! Please open an issue or PR.

## License

MIT License - see [LICENSE](LICENSE) for details.
