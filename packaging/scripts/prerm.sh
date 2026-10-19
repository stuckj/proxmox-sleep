#!/bin/bash
# Pre-removal script for proxmox-sleep

set -e

# On an upgrade both units are left as they are, and postinst restarts the
# monitor onto the new script. Disabling here would leave a monitor the user
# enabled by hand off whenever postinst's config check does not re-enable it.
# dpkg passes upgrade or failed-upgrade; rpm passes the number of instances that
# will remain, which is 1 or more on an upgrade and 0 on a final erase.
case "${1:-remove}" in
    upgrade|failed-upgrade|[1-9]*) exit 0 ;;
esac

# Stop and disable services (ignore errors if they don't exist or aren't running)
systemctl stop proxmox-idle-monitor.service 2>/dev/null || true
systemctl stop proxmox-sleep-manager.service 2>/dev/null || true
systemctl disable proxmox-idle-monitor.service 2>/dev/null || true
systemctl disable proxmox-sleep-manager.service 2>/dev/null || true

exit 0
