#!/bin/bash
#
# Uninstall script for Proxmox Sleep Manager
#

set -e

INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_FILE="/etc/proxmox-sleep.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "===================================="
echo "Proxmox Sleep Manager Uninstallation"
echo "===================================="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

echo "This will remove:"
echo "  - Systemd services"
echo "  - Scripts from $INSTALL_DIR"
echo "  - Log files"
echo ""
echo -e "${YELLOW}Note: Config file ($CONFIG_FILE) will be preserved${NC}"
echo ""
read -p "Continue with uninstallation? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Uninstallation cancelled"
    exit 0
fi

echo ""
echo "Stopping and disabling services..."

# Stop and disable services (ignore errors if they don't exist)
systemctl stop proxmox-idle-monitor.service 2>/dev/null || true
systemctl stop proxmox-sleep-manager.service 2>/dev/null || true
systemctl disable proxmox-idle-monitor.service 2>/dev/null || true
systemctl disable proxmox-sleep-manager.service 2>/dev/null || true

echo -e "${GREEN}✓ Services stopped${NC}"

echo "Removing systemd service files..."
rm -f "$SYSTEMD_DIR/proxmox-sleep-manager.service"
rm -f "$SYSTEMD_DIR/proxmox-idle-monitor.service"
systemctl daemon-reload
echo -e "${GREEN}✓ Service files removed${NC}"

echo "Removing scripts..."
rm -f "$INSTALL_DIR/proxmox-sleep-manager.sh"
rm -f "$INSTALL_DIR/proxmox-idle-monitor.sh"
echo -e "${GREEN}✓ Scripts removed${NC}"

echo "Removing log files..."
rm -f /var/log/proxmox-sleep-manager.log
rm -f /var/log/proxmox-idle-monitor.log
rm -f /var/log/proxmox-sleep-manager.log.* 2>/dev/null || true
rm -f /var/log/proxmox-idle-monitor.log.* 2>/dev/null || true
echo -e "${GREEN}✓ Log files removed${NC}"

echo "Removing logrotate config..."
rm -f /etc/logrotate.d/proxmox-sleep
echo -e "${GREEN}✓ Logrotate config removed${NC}"

echo "Removing state files..."
rm -f /tmp/proxmox-sleep-manager.state
rm -f /tmp/proxmox-idle-monitor.state
echo -e "${GREEN}✓ State files removed${NC}"

echo ""
echo "===================================="
echo -e "${GREEN}Uninstallation Complete!${NC}"
echo "===================================="
echo ""
if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}Config file preserved at: $CONFIG_FILE${NC}"
    echo "Remove manually if no longer needed:"
    echo "  rm $CONFIG_FILE"
fi
echo ""
