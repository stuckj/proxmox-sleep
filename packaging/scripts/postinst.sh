#!/bin/bash
# Post-installation script for proxmox-sleep

set -e

# Reload systemd to pick up new service files
systemctl daemon-reload

# Create log files with correct permissions
touch /var/log/proxmox-sleep-manager.log
touch /var/log/proxmox-idle-monitor.log
chmod 644 /var/log/proxmox-sleep-manager.log
chmod 644 /var/log/proxmox-idle-monitor.log

# Always enable the sleep manager - it's safe (only acts on sleep events)
systemctl enable proxmox-sleep-manager.service

# Check if config file exists and is valid
CONFIG_FILE="/etc/proxmox-sleep.conf"
ENABLE_IDLE_MONITOR=0

if [[ -f "$CONFIG_FILE" ]]; then
    # Source the config to check VMID
    source "$CONFIG_FILE"

    # Check if VMID is set and VM exists
    if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
        ENABLE_IDLE_MONITOR=1
    fi
fi

if [[ $ENABLE_IDLE_MONITOR -eq 1 ]]; then
    echo "Existing valid configuration found. Enabling idle monitor..."
    systemctl enable proxmox-idle-monitor.service
    systemctl start proxmox-idle-monitor.service || true
else
    echo ""
    echo "=============================================="
    echo "  Proxmox Sleep Manager installed!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Create the configuration file:"
    echo "     cp /usr/share/doc/proxmox-sleep/examples/proxmox-sleep.conf.example /etc/proxmox-sleep.conf"
    echo ""
    echo "  2. Edit the configuration and set your VM ID:"
    echo "     nano /etc/proxmox-sleep.conf"
    echo ""
    echo "  3. Enable the idle monitor:"
    echo "     systemctl enable --now proxmox-idle-monitor"
    echo ""
    echo "  4. Install the Windows idle helper (required for accurate idle detection):"
    echo "     proxmox-idle-monitor.sh install-helper"
    echo ""
    echo "The sleep manager is already enabled and will hibernate your VM"
    echo "when the system sleeps (once configured)."
    echo ""
fi

exit 0
