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

```bash
# Clone or copy files to your Proxmox host
git clone https://github.com/YOUR_USERNAME/proxmox-sleep.git
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
# Sleep manager status
proxmox-sleep-manager.sh status

# Idle monitor status (is system idle right now?)
proxmox-idle-monitor.sh check

# Detailed debug output
DEBUG=1 proxmox-idle-monitor.sh check
```

### Manual Operations
```bash
# Hibernate the VM manually
proxmox-sleep-manager.sh hibernate

# Sleep the host (will trigger VM hibernation)
systemctl suspend

# Wake: use WoL or press power button
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

| Check | Method | GPU Support |
|-------|--------|-------------|
| VM CPU Usage | Proxmox API | N/A |
| GPU Usage | Guest Agent | NVIDIA, AMD |
| Windows Idle Time | Guest Agent (user32.dll) | N/A |
| Gaming Processes | Guest Agent (Get-Process) | N/A |
| SSH Sessions | Host `who` command | N/A |

All must indicate "idle" for the configured duration before triggering sleep.

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
