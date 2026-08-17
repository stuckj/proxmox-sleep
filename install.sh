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

# Get VM ID (optional — leave blank to skip)
read -rp "Enter your Windows VM ID (leave blank to skip): " vmid
VMID=${vmid:-}

if [[ -n "$VMID" && ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: VM ID must be a positive integer (got: '$VMID')${NC}"
    exit 1
fi

VM_NAME=""
if [[ -n "$VMID" ]] && qm status "$VMID" &>/dev/null; then
    # `name:` is optional in a VM config; without || true the failing grep
    # would abort the installer under `set -e` before the :- fallback runs.
    VM_NAME=$(qm config "$VMID" | grep "^name:" | awk '{print $2}' || true)
    VM_NAME=${VM_NAME:-windows-vm}
    echo -e "${GREEN}Found VM: $VM_NAME (ID: $VMID)${NC}"
elif [[ -n "$VMID" ]]; then
    echo -e "${YELLOW}Warning: VM $VMID does not exist — you can fix this in the config later${NC}"
fi

# Get container ID (optional)
read -rp "Enter an LXC container ID to manage (leave blank to skip): " ctid
CTID=${ctid:-}

if [[ -n "$CTID" && ! "$CTID" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: Container ID must be a positive integer (got: '$CTID')${NC}"
    exit 1
fi

CT_NAME=""
if [[ -n "$CTID" ]] && pct status "$CTID" &>/dev/null; then
    CT_NAME=$(pct config "$CTID" | grep "^hostname:" | awk '{print $2}' || true)
    CT_NAME=${CT_NAME:-linux-ct}
    echo -e "${GREEN}Found container: $CT_NAME (ID: $CTID)${NC}"
elif [[ -n "$CTID" ]]; then
    echo -e "${YELLOW}Warning: Container $CTID does not exist — you can fix this in the config later${NC}"
fi

# Get idle threshold
read -rp "Auto-sleep after how many idle minutes? [15]: " idle_mins
IDLE_MINUTES=${idle_mins:-15}

if [[ ! "$IDLE_MINUTES" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: Idle threshold must be a non-negative integer (got: '$IDLE_MINUTES')${NC}"
    exit 1
fi

echo ""
echo "Configuration:"
[[ -n "$VMID" ]] && echo "  VM ID: $VMID ($VM_NAME)"
[[ -n "$CTID" ]] && echo "  Container ID: $CTID ($CT_NAME)"
echo "  Idle Threshold: $IDLE_MINUTES minutes"
echo ""
echo -e "${YELLOW}Tip: You can add more VMs/containers later by editing /etc/proxmox-sleep.conf${NC}"
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

# Create or update config file
if [[ ! -f /etc/proxmox-sleep.conf ]]; then
    cp "$SCRIPT_DIR/proxmox-sleep.conf.example" /etc/proxmox-sleep.conf

    # Patch the example with user-provided values
    sed -i "s/^IDLE_THRESHOLD_MINUTES=.*/IDLE_THRESHOLD_MINUTES=$IDLE_MINUTES/" /etc/proxmox-sleep.conf

    if [[ -n "$VMID" ]]; then
        ESCAPED_VMID=$(escape_sed "$VMID")
        ESCAPED_VM_NAME=$(escape_sed "$VM_NAME")
        sed -i "s/^VM_IDS=.*/VM_IDS=\"$ESCAPED_VMID\"/" /etc/proxmox-sleep.conf
        # Re-key the entire VM_100_* block to VM_<VMID>_* so all per-instance
        # settings (MONITOR, SLEEP_ACTION, GAMING_PROCESSES, etc.) apply.
        if [[ "$ESCAPED_VMID" != "100" ]]; then
            sed -i "s/^VM_100_/VM_${ESCAPED_VMID}_/" /etc/proxmox-sleep.conf
        fi
        sed -i "s/^VM_${ESCAPED_VMID}_NAME=.*/VM_${ESCAPED_VMID}_NAME=\"$ESCAPED_VM_NAME\"/" /etc/proxmox-sleep.conf
    else
        # No VM configured — blank out the default VM_IDS so the idle monitor
        # doesn't try to validate a VM that isn't there.
        sed -i 's/^VM_IDS=.*/VM_IDS=""/' /etc/proxmox-sleep.conf
    fi

    if [[ -n "$CTID" ]]; then
        ESCAPED_CTID=$(escape_sed "$CTID")
        # Uncomment container lines and set values
        sed -i "s/^CONTAINER_IDS=.*/CONTAINER_IDS=\"$ESCAPED_CTID\"/" /etc/proxmox-sleep.conf
        # Append container config if not already present
        # Anchored: the example config ships a commented CONTAINER_200_NAME=,
        # so an unanchored match would skip the block for the documented CTID.
        if ! grep -q "^CONTAINER_${CTID}_NAME=" /etc/proxmox-sleep.conf; then
            cat >> /etc/proxmox-sleep.conf <<EOF

# Container $CTID
CONTAINER_${CTID}_NAME="$CT_NAME"
CONTAINER_${CTID}_MONITOR=1
CONTAINER_${CTID}_SLEEP_ACTION=shutdown
CONTAINER_${CTID}_RESUME_ON_WAKE=1
CONTAINER_${CTID}_GAMING_PROCESSES="steam,steamwebhelper,wine,wineserver,proton,gamescope"
EOF
        fi
    fi
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

# An existing config is deliberately left untouched above, so the answers to
# the prompts say nothing about what is configured. Read the file before
# claiming nothing is.
CONFIGURED=0
if [[ -n "$VMID" || -n "$CTID" ]]; then
    CONFIGURED=1
elif [[ $EXISTING_CONFIG -eq 1 ]]; then
    if (
        # shellcheck source=/dev/null
        source /etc/proxmox-sleep.conf
        [[ -n "${VM_IDS:-}${CONTAINER_IDS:-}${VMID:-}" ]]
    ); then
        CONFIGURED=1
    fi
fi

if [[ $CONFIGURED -eq 0 ]]; then
    echo -e "${YELLOW}⚠ No VM or container configured — skipping idle monitor${NC}"
    echo -e "${YELLOW}  The idle monitor requires at least one VM or container to watch.${NC}"
    echo -e "${YELLOW}  Add VM_IDS or CONTAINER_IDS to /etc/proxmox-sleep.conf and then run:${NC}"
    echo -e "${YELLOW}    systemctl enable --now proxmox-idle-monitor${NC}"
else
    read -rp "Enable auto-sleep monitoring? [Y/n]: " enable_idle
    if [[ ! "$enable_idle" =~ ^[Nn] ]]; then
        systemctl enable proxmox-idle-monitor.service
        systemctl start proxmox-idle-monitor.service
        echo -e "${GREEN}✓ Idle monitor enabled and started${NC}"
    else
        echo -e "${YELLOW}⚠ Idle monitor not enabled (you can enable later with: systemctl enable --now proxmox-idle-monitor)${NC}"
    fi
fi

echo ""
echo "=================================="
echo -e "${GREEN}Installation Complete!${NC}"
echo "=================================="
echo ""
echo "Configuration:"
echo "  /etc/proxmox-sleep.conf"
echo ""
echo "Next steps:"
echo "  - If managing a Windows VM, install the idle helper:"
echo "    proxmox-idle-monitor.sh install-helper"
echo "  - To add more VMs/containers, edit /etc/proxmox-sleep.conf"
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
