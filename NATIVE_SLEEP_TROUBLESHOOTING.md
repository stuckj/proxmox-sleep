# Attempting Native Sleep with GPU Passthrough

Native sleep (S3) with a Windows VM and GPU passthrough is challenging but sometimes possible. Here are things to try before falling back to the hibernation approach.

## Why It Usually Fails

1. **GPU Reset Issues**: NVIDIA GPUs need a proper reset on wake. The GPU doesn't properly reinitialize after S3.
2. **VFIO State**: The VFIO-PCI driver may not properly save/restore device state.
3. **Windows Driver**: NVIDIA Windows drivers don't expect the GPU to "disappear" and reappear.
4. **IOMMU State**: The IOMMU mappings may get corrupted during suspend.

## Things to Try

### 1. Check Your GPU's Reset Capability

```bash
# Check if your GPU supports Function Level Reset (FLR)
lspci -vvv -s <GPU_PCI_ADDRESS> | grep -i "flr"

# Example: lspci -vvv -s 01:00.0 | grep -i "flr"
```

If FLR is supported, that's a good sign. If not, reset issues are more likely.

### 2. Enable VFIO Power Management

Add to `/etc/modprobe.d/vfio.conf`:
```
options vfio-pci enable_sriov=0 disable_idle_d3=0
```

### 3. Kernel Parameters

Add to `/etc/default/grub` in `GRUB_CMDLINE_LINUX_DEFAULT`:
```
intel_iommu=on iommu=pt pcie_acs_override=downstream,multifunction
```

Or for AMD:
```
amd_iommu=on iommu=pt pcie_acs_override=downstream,multifunction
```

Then run: `update-grub && reboot`

### 4. Try Suspending the VM First (Not Hibernation)

Some users report success with this sequence:
```bash
# Before host sleep:
qm suspend <VMID> --todisk 0   # RAM-based suspend

# After host wake:
qm resume <VMID>
```

This keeps the VM's memory in RAM on the host.

### 5. GPU-Specific Workarounds

#### For NVIDIA GPUs:
The `vendor-reset` project doesn't help NVIDIA cards (it's for AMD), but you can try:

```bash
# Before sleep, unbind the GPU from vfio-pci
echo "<PCI_ADDRESS>" > /sys/bus/pci/drivers/vfio-pci/unbind

# After wake, rebind
echo "<PCI_ADDRESS>" > /sys/bus/pci/drivers/vfio-pci/bind
```

This is risky and may crash the VM, but some report it helps.

### 6. Windows Power Settings

Inside Windows VM:
1. Open Power Options
2. Change plan settings → Change advanced power settings
3. PCI Express → Link State Power Management → **Off**
4. Graphics settings → **Maximum Performance**

### 7. BIOS/UEFI Settings

Check your motherboard BIOS for:
- **Above 4G Decoding**: Enable
- **Resizable BAR**: Try both enabled and disabled
- **IOMMU**: Enable
- **PCIe Power Management**: Disable/Off
- **ASPM**: Disable

### 8. Test with VM Stopped

Before trying with VM running, verify host sleep works at all:
```bash
# Stop the VM
qm stop <VMID>

# Test sleep
systemctl suspend

# Wake up and check stability
```

If this works but sleep-with-VM doesn't, the issue is specifically the GPU passthrough during suspend.

## Monitoring What Goes Wrong

Enable verbose logging:
```bash
# Before sleeping
dmesg -w > /tmp/sleep-log.txt &

# Sleep
systemctl suspend

# After wake, check the log
less /tmp/sleep-log.txt
```

Look for errors related to:
- `vfio-pci`
- `nvidia` or your GPU
- `iommu`
- `pci`

## The Nuclear Option: Script to Detach/Reattach GPU

If you really want native sleep and can tolerate the VM "crashing" through sleep, you could:

1. Before sleep: Stop VM, unbind GPU from vfio-pci
2. Sleep
3. After wake: Rebind GPU to vfio-pci, start VM

This effectively makes sleep work at the cost of VM restart (similar to hibernation but faster wake for the host).

## When to Give Up

If you've tried everything and sleep still causes:
- ZFS corruption
- System reboots
- GPU hangs requiring power cycle

Then the hibernation approach in this project is your best bet. It's more reliable and, while VM resume takes ~30-60 seconds from hibernation, it's still much faster than a full Windows boot and preserves your session.
