#!/bin/bash
# Post-installation script for proxmox-sleep

set -e

# `daemon-reload` and `start` talk to a running systemd, which a container,
# chroot or image build does not have, and under set -e their failure is reported
# as a failed install. `enable` only writes symlinks, so it runs either way and
# an image built this way comes up with the units enabled.
have_systemctl() { command -v systemctl >/dev/null 2>&1; }
systemd_running() { [ -d /run/systemd/system ]; }

# Reload systemd to pick up new service files
if systemd_running; then
    systemctl daemon-reload
fi

# Create log files with correct permissions
touch /var/log/proxmox-sleep-manager.log
touch /var/log/proxmox-idle-monitor.log
chmod 644 /var/log/proxmox-sleep-manager.log
chmod 644 /var/log/proxmox-idle-monitor.log

# Always enable the sleep manager - it's safe (only acts on sleep events)
if have_systemctl; then
    systemctl enable proxmox-sleep-manager.service
fi

# Check if config file exists and is valid
CONFIG_FILE="/etc/proxmox-sleep.conf"
ENABLE_IDLE_MONITOR=0

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # prerm disables the idle monitor on every upgrade, so anything not
    # re-enabled here stays off after `apt upgrade`. Accept the multi-instance
    # format as well as legacy VMID=, or a working install silently stops
    # sleeping the host.
    if [[ -n "${VM_IDS:-}" || -n "${CONTAINER_IDS:-}" ]]; then
        ENABLE_IDLE_MONITOR=1
    elif [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
        ENABLE_IDLE_MONITOR=1
    fi
fi

if [[ $ENABLE_IDLE_MONITOR -eq 1 ]]; then
    echo "Existing valid configuration found. Enabling idle monitor..."
    if have_systemctl; then
        systemctl enable proxmox-idle-monitor.service
    fi
    # restart rather than start: prerm leaves the monitor running across an
    # upgrade, and a running monitor would otherwise keep the old script.
    if systemd_running; then
        systemctl restart proxmox-idle-monitor.service || true
    fi
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
