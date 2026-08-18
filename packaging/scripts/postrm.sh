#!/bin/bash
# Post-removal script for proxmox-sleep

# Reload systemd to clean up removed service files
systemctl daemon-reload || true

# Clean up runtime state directory — but not on upgrade, where dpkg also runs
# this script. The state file can hold an instance that failed to resume and is
# still waiting for `proxmox-sleep-manager.sh resume`.
# dpkg passes remove/purge/upgrade; rpm passes a count, 0 on final erase.
case "${1:-remove}" in
    remove|purge|0) rm -rf /run/proxmox-sleep ;;
esac
# Clean up legacy /tmp state files from pre-/run versions
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
