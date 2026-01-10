#!/bin/bash
# Post-removal script for proxmox-sleep

# Reload systemd to clean up removed service files
systemctl daemon-reload || true

# Clean up state files
rm -f /tmp/proxmox-sleep-manager.state
rm -f /tmp/proxmox-idle-monitor.state
rm -f /tmp/proxmox-idle-monitor.wake

# Note: We don't remove log files or config file
# - Log files may be useful for debugging
# - Config file should be preserved for reinstalls (marked as conffile)

echo ""
echo "Proxmox Sleep Manager has been removed."
echo ""
echo "The following files have been preserved:"
echo "  - /etc/proxmox-sleep.conf (if exists)"
echo "  - /var/log/proxmox-sleep-manager.log"
echo "  - /var/log/proxmox-idle-monitor.log"
echo ""
echo "Remove them manually if no longer needed."
echo ""

exit 0
