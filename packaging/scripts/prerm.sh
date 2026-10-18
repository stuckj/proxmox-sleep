#!/bin/bash
# Pre-removal script for proxmox-sleep

set -e

# On an upgrade both units are left as they are. rpm runs the old package's
# %preun *after* the new package's %post, so stopping or disabling here would
# undo what the new postinst just did and leave the host no longer auto-sleeping.
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
