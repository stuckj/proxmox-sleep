# Proxmox Sleep Manager

Automated power management for Proxmox hosts with Windows VMs and GPU passthrough.

## The Problem

- Gaming desktop runs Proxmox with Windows 11 VM + GPU passthrough
- Machine draws ~150W idle, but only used a few hours per week
- Native sleep (S3) with GPU passthrough often causes issues (crashes, ZFS corruption)
- Windows VM suspend via QEMU doesn't survive host sleep
- Want the machine to auto-sleep when idle

## The Solution

This project provides two components:

1. **Sleep Manager**: Automatically hibernates the Windows VM before host sleep and resumes it after wake
2. **Idle Monitor**: Detects when the system is truly idle and triggers sleep

### How It Works

```
Host Going to Sleep:
┌─────────────┐    ┌──────────────────┐    ┌─────────────┐    ┌────────────┐
│ systemctl   │───>│ sleep-manager    │───>│ Windows     │───>│ Host       │
│ suspend     │    │ (pre-sleep hook) │    │ hibernates  │    │ sleeps     │
└─────────────┘    └──────────────────┘    └─────────────┘    └────────────┘

Host Waking Up:
┌─────────────┐    ┌──────────────────┐    ┌─────────────┐
│ Host wakes  │───>│ sleep-manager    │───>│ VM starts   │
│             │    │ (post-wake hook) │    │ (resumes    │
│             │    │                  │    │ from hib.)  │
└─────────────┘    └──────────────────┘    └─────────────┘
```

Windows hibernation writes RAM to disk, so when the VM starts, it resumes exactly where it left off.

## Requirements

- Proxmox VE (tested on 7.x and 8.x)
- Windows VM with QEMU Guest Agent installed
- Hibernation enabled in Windows (usually is by default)
- GPU passthrough with NVIDIA or AMD graphics card

### Enabling Windows Hibernation

If hibernation is disabled, enable it in an elevated PowerShell:
```powershell
powercfg /hibernate on
```

## Installation

### Step 1: Install on Proxmox Host

```bash
# Clone or copy files to your Proxmox host
git clone https://github.com/stuckj/proxmox-sleep.git
cd proxmox-sleep

# Run installer (as root)
chmod +x install.sh
./install.sh
```

The installer will:
- Ask for your VM ID and idle threshold
- Install scripts to `/usr/local/bin`
- Create config file at `/etc/proxmox-sleep.conf`
- Configure and enable systemd services
- Optionally enable auto-sleep monitoring

### Step 2: Install Windows Idle Helper (Required)

> **Important**: This step is required for proper keyboard/mouse idle detection with USB passthrough devices.

The QEMU guest agent runs as SYSTEM in Windows session 0, which cannot detect user input from USB passthrough keyboards and mice. A small helper application must run in your Windows user session to track idle time.

From the Proxmox host, run:
```bash
proxmox-idle-monitor.sh install-helper
```

This installs a Windows scheduled task that:
- Runs automatically at user logon
- Displays a **system tray icon** showing current idle time (hover to see)
- Updates idle time every 10 seconds
- Can be exited by right-clicking the tray icon

The tray icon appears as an "i" (information) icon and shows "Idle: Xm Ys" when you hover over it.

## Manual Installation

```bash
# Copy scripts
cp proxmox-sleep-manager.sh /usr/local/bin/
cp proxmox-idle-monitor.sh /usr/local/bin/
chmod +x /usr/local/bin/proxmox-*.sh

# Create and edit config file
cp proxmox-sleep.conf.example /etc/proxmox-sleep.conf
nano /etc/proxmox-sleep.conf  # Edit VMID and other settings

# Copy and edit service files (replace __VMID__, __VM_NAME__, __IDLE_MINUTES__)
cp proxmox-sleep-manager.service /etc/systemd/system/
cp proxmox-idle-monitor.service /etc/systemd/system/

# Enable services
systemctl daemon-reload
systemctl enable proxmox-sleep-manager.service
systemctl enable --now proxmox-idle-monitor.service
```

## Usage

### Check Status
```bash
# Full status with idle tracking info
proxmox-idle-monitor.sh status

# Quick idle check (for testing)
proxmox-idle-monitor.sh check

# Detailed debug output
DEBUG=1 proxmox-idle-monitor.sh check

# Sleep manager status
proxmox-sleep-manager.sh status
```

### Sleep Now (Manual Sleep)
```bash
# Immediately hibernate VM and sleep the host
proxmox-idle-monitor.sh sleep-now
```

This is useful for:
- Testing the sleep/wake cycle
- Manually sleeping the machine without waiting for idle timeout
- Quick shutdown when leaving

### Other Operations
```bash
# Hibernate the VM only (without sleeping host)
proxmox-sleep-manager.sh hibernate

# Reset idle tracking (restart the countdown)
proxmox-idle-monitor.sh reset

# Reinstall Windows idle helper
proxmox-idle-monitor.sh install-helper

# Wake: use Wake-on-LAN or press power button
```

### Logs
```bash
tail -f /var/log/proxmox-sleep-manager.log
tail -f /var/log/proxmox-idle-monitor.log
```

## Configuration

All settings can be configured in `/etc/proxmox-sleep.conf`:

```bash
# VM Configuration
VMID=100                          # Your VM ID
VM_NAME="windows"                 # VM name for logging

# Idle Monitor Settings
IDLE_THRESHOLD_MINUTES=15         # Minutes before auto-sleep
CHECK_INTERVAL=60                 # Check interval in seconds
CPU_IDLE_THRESHOLD=15             # CPU usage % threshold
GPU_IDLE_THRESHOLD=10             # GPU usage % threshold
GPU_VENDOR=auto                   # nvidia, amd, or auto

# Hibernation Settings
HIBERNATE_TIMEOUT=300             # Max wait for hibernation
WAKE_DELAY=5                      # Delay after wake before starting VM

# Gaming Process Detection
GAMING_PROCESSES="steam.exe,EpicGamesLauncher.exe,..."
EXTRA_GAMING_PROCESSES=""         # Add your own without modifying defaults

# Logging
DEBUG=0                           # Set to 1 for verbose logging
```

See `proxmox-sleep.conf.example` for all available options.

Environment variables override config file settings, which override defaults.

## Idle Detection

The idle monitor checks multiple signals:

| Check | Method | Notes |
|-------|--------|-------|
| VM CPU Usage | Proxmox API | Above threshold = active |
| GPU Usage | Guest Agent (nvidia-smi/perf counters) | NVIDIA, AMD supported |
| Windows Idle Time | Tray Helper App | Requires install-helper |
| Windows Power Requests | Guest Agent (powercfg) | Media players, downloads, etc. |
| Gaming Processes | Guest Agent (Get-Process) | Configurable process list |
| SSH Sessions | Host `who` command | Optional, can disable |

All must indicate "idle" for the configured duration before triggering sleep.

### Windows Idle Helper

The idle helper is essential for accurate keyboard/mouse detection. Without it:
- The system falls back to screensaver/lock detection only
- USB passthrough input won't be detected
- The system may sleep while you're actively using it

The helper runs silently with a system tray icon. If the icon is missing, reinstall:
```bash
proxmox-idle-monitor.sh install-helper
```

### Power Request Filtering

Windows applications can request the system stay awake (e.g., media players, downloads). The idle monitor detects these via `powercfg /requests`.

Some system-level requests are filtered as noise:
- "Legacy Kernel Caller" - AMD CPU power management
- "Sleep Idle State Disabled" - System idle tracking

These don't indicate real user activity and are ignored.

### GPU Detection

- **NVIDIA**: Uses `nvidia-smi` inside the Windows VM
- **AMD**: Uses Windows performance counters
- **Auto** (default): Tries NVIDIA first, then AMD, then generic Windows counters

### Customizing Gaming Detection

Edit `/etc/proxmox-sleep.conf`:

```bash
# Add to the existing list
GAMING_PROCESSES="steam.exe,EpicGamesLauncher.exe,GalaxyClient.exe"

# Or add extras without modifying defaults
EXTRA_GAMING_PROCESSES="Cyberpunk2077.exe,eldenring.exe,Palworld-Win64-Shipping.exe"
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
# Install/reinstall the helper
proxmox-idle-monitor.sh install-helper
```

Then log out and back in to Windows, or check Task Scheduler for "ProxmoxIdleHelper".

### Tray icon not visible
- Check Windows system tray overflow (click the ^ arrow)
- The icon appears as an "i" (information icon)
- Right-click to exit, then restart via Task Scheduler or re-run install-helper

### GPU usage not detected
```bash
# Test NVIDIA detection
qm guest exec <VMID> -- cmd /c "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits"

# Check GPU_VENDOR setting in config
grep GPU_VENDOR /etc/proxmox-sleep.conf
```

## Uninstalling

```bash
# Run the uninstall script
chmod +x uninstall.sh
./uninstall.sh
```

Or manually:
```bash
systemctl disable --now proxmox-sleep-manager.service
systemctl disable --now proxmox-idle-monitor.service
rm /etc/systemd/system/proxmox-sleep-manager.service
rm /etc/systemd/system/proxmox-idle-monitor.service
rm /usr/local/bin/proxmox-sleep-manager.sh
rm /usr/local/bin/proxmox-idle-monitor.sh
rm /etc/proxmox-sleep.conf  # Optional: keep for reinstall
systemctl daemon-reload
```

## Contributing

Contributions welcome! Please open an issue or PR.

## License

MIT License - see [LICENSE](LICENSE) for details.
