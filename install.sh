#!/bin/bash
#
# Installation script for Proxmox Sleep Manager
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/lib/systemd/system"
DOC_DIR="/usr/share/doc/proxmox-sleep"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=================================="
echo "Proxmox Sleep Manager Installation"
echo "=================================="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Check for existing config file
EXISTING_CONFIG=0
if [[ -f /etc/proxmox-sleep.conf ]]; then
    EXISTING_CONFIG=1
    echo -e "${YELLOW}Note: Existing config file found at /etc/proxmox-sleep.conf${NC}"
    echo ""
fi

# Get VM ID
read -p "Enter your Windows VM ID [100]: " vmid
VMID=${vmid:-100}

# Verify VM exists
if ! qm status "$VMID" &>/dev/null; then
    echo -e "${RED}Error: VM $VMID does not exist${NC}"
    exit 1
fi

# Get VM name for logging
VM_NAME=$(qm config "$VMID" | grep "^name:" | awk '{print $2}')
VM_NAME=${VM_NAME:-windows-vm}
echo -e "${GREEN}Found VM: $VM_NAME (ID: $VMID)${NC}"

# Get idle threshold
read -p "Auto-sleep after how many idle minutes? [15]: " idle_mins
IDLE_MINUTES=${idle_mins:-15}

echo ""
echo "Configuration:"
echo "  VM ID: $VMID"
echo "  VM Name: $VM_NAME"
echo "  Idle Threshold: $IDLE_MINUTES minutes"
echo ""
read -p "Continue with installation? [Y/n]: " confirm
if [[ "$confirm" =~ ^[Nn] ]]; then
    echo "Installation cancelled"
    exit 0
fi

echo ""
echo "Installing scripts..."

# Install main scripts
cp "$SCRIPT_DIR/proxmox-sleep-manager.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/proxmox-idle-monitor.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/proxmox-sleep-manager.sh"
chmod +x "$INSTALL_DIR/proxmox-idle-monitor.sh"
echo -e "${GREEN}✓ Scripts installed to $INSTALL_DIR${NC}"

# Install systemd services
echo "Installing systemd services..."
cp "$SCRIPT_DIR/proxmox-sleep-manager.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/proxmox-idle-monitor.service" "$SYSTEMD_DIR/"
echo -e "${GREEN}✓ Systemd services installed${NC}"

# Reload systemd
systemctl daemon-reload

# Create log files
touch /var/log/proxmox-sleep-manager.log
touch /var/log/proxmox-idle-monitor.log
chmod 644 /var/log/proxmox-sleep-manager.log
chmod 644 /var/log/proxmox-idle-monitor.log

# Install logrotate config
cp "$SCRIPT_DIR/proxmox-sleep.logrotate" /etc/logrotate.d/proxmox-sleep
echo -e "${GREEN}✓ Logrotate config installed${NC}"

# Install documentation
mkdir -p "$DOC_DIR/examples"
cp "$SCRIPT_DIR/proxmox-sleep.conf.example" "$DOC_DIR/examples/"
cp "$SCRIPT_DIR/README.md" "$DOC_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/LICENSE" "$DOC_DIR/" 2>/dev/null || true
echo -e "${GREEN}✓ Documentation installed${NC}"

# Escape special characters for sed replacement (& \ /)
escape_sed() {
    printf '%s' "$1" | sed 's/[&/\]/\\&/g'
}

ESCAPED_VMID=$(escape_sed "$VMID")
ESCAPED_VM_NAME=$(escape_sed "$VM_NAME")
ESCAPED_IDLE_MINUTES=$(escape_sed "$IDLE_MINUTES")

# Create or update config file
if [[ ! -f /etc/proxmox-sleep.conf ]]; then
    cp "$SCRIPT_DIR/proxmox-sleep.conf.example" /etc/proxmox-sleep.conf
    sed -i "s/^VMID=.*/VMID=$ESCAPED_VMID/" /etc/proxmox-sleep.conf
    sed -i "s/^VM_NAME=.*/VM_NAME=\"$ESCAPED_VM_NAME\"/" /etc/proxmox-sleep.conf
    sed -i "s/^IDLE_THRESHOLD_MINUTES=.*/IDLE_THRESHOLD_MINUTES=$ESCAPED_IDLE_MINUTES/" /etc/proxmox-sleep.conf
    echo -e "${GREEN}✓ Config file created at /etc/proxmox-sleep.conf${NC}"
else
    echo -e "${YELLOW}⚠ Config file already exists at /etc/proxmox-sleep.conf${NC}"
    echo -e "${YELLOW}  Edit /etc/proxmox-sleep.conf to change settings.${NC}"
fi

# Enable services
echo ""
echo "Enabling services..."
systemctl enable proxmox-sleep-manager.service
echo -e "${GREEN}✓ Sleep manager enabled (will hibernate VM before sleep)${NC}"

read -p "Enable auto-sleep monitoring? [Y/n]: " enable_idle
if [[ ! "$enable_idle" =~ ^[Nn] ]]; then
    systemctl enable proxmox-idle-monitor.service
    systemctl start proxmox-idle-monitor.service
    echo -e "${GREEN}✓ Idle monitor enabled and started${NC}"
else
    echo -e "${YELLOW}⚠ Idle monitor not enabled (you can enable later with: systemctl enable --now proxmox-idle-monitor)${NC}"
fi

echo ""
echo "=================================="
echo -e "${GREEN}Installation Complete!${NC}"
echo "=================================="
echo ""
echo "Configuration:"
echo "  /etc/proxmox-sleep.conf"
echo ""
echo "Next step - Install Windows idle helper:"
echo "  proxmox-idle-monitor.sh install-helper"
echo ""
echo "Commands:"
echo "  proxmox-sleep-manager.sh status   - Check sleep manager status"
echo "  proxmox-idle-monitor.sh status    - Check idle monitor status"
echo "  proxmox-idle-monitor.sh check     - One-time idle check"
echo ""
echo "Logs:"
echo "  /var/log/proxmox-sleep-manager.log"
echo "  /var/log/proxmox-idle-monitor.log"
echo ""
echo "Services:"
echo "  systemctl status proxmox-sleep-manager"
echo "  systemctl status proxmox-idle-monitor"
echo ""
