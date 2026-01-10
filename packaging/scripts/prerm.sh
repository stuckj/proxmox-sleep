#!/bin/bash
# Pre-removal script for proxmox-sleep

set -e

# Stop and disable services (ignore errors if they don't exist or aren't running)
systemctl stop proxmox-idle-monitor.service 2>/dev/null || true
systemctl stop proxmox-sleep-manager.service 2>/dev/null || true
systemctl disable proxmox-idle-monitor.service 2>/dev/null || true
systemctl disable proxmox-sleep-manager.service 2>/dev/null || true

exit 0
