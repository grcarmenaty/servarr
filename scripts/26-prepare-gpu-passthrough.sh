#!/usr/bin/env bash
# Prepare THIS node to pass a GPU through to a VM (docs/16): bind the card
# to vfio-pci at boot and keep host drivers off it. Requires a reboot.
#
#   lspci -nn | grep -i nvidia          # find the address, e.g. 01:00.0
#   bash 26-prepare-gpu-passthrough.sh 01:00
#
# Pass the address WITHOUT the trailing .0 — the script grabs every
# function (GPU + its audio device).

source "$(dirname "$0")/lib.sh"
require_root
require_pve

ADDR="${1:-}"
[[ "$ADDR" =~ ^[0-9a-f]{2}:[0-9a-f]{2}$ ]] || die "usage: $0 <pci-addr like 01:00>   (see: lspci -nn | grep -i nvidia)"

lspci -s "$ADDR" >/dev/null 2>&1 || die "no device at ${ADDR} on this node"
echo "Device(s) at ${ADDR}:"
lspci -nns "$ADDR"

# vendor:device ids for every function (e.g. 10de:1b38 + 10de:10f0 audio)
IDS="$(lspci -ns "$ADDR" | awk '{print $3}' | sort -u | paste -sd, -)"
[[ -n "$IDS" ]] || die "could not read PCI ids"
log "vfio-pci ids: ${IDS}"

log "1/4 IOMMU check"
if ! dmesg | grep -qiE 'IOMMU enabled|AMD-Vi|DMAR: IOMMU'; then
    warn "IOMMU not clearly active — ensure it's enabled in BIOS (AMD-Vi/IOMMU)"
fi
if ! grep -q 'iommu=pt' /etc/default/grub; then
    log "adding iommu=pt to kernel cmdline"
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 iommu=pt"/' /etc/default/grub
    update-grub
fi

log "2/4 vfio modules"
for m in vfio vfio_iommu_type1 vfio_pci; do
    grep -qx "$m" /etc/modules || echo "$m" >> /etc/modules
done

log "3/4 binding ${IDS} to vfio-pci + blacklisting host GPU drivers"
cat > /etc/modprobe.d/vfio-gpu.conf <<EOF
options vfio-pci ids=${IDS}
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
EOF
cat > /etc/modprobe.d/blacklist-gpu.conf <<'EOF'
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
EOF

log "4/4 rebuilding initramfs"
update-initramfs -u -k all

echo
log "Done. REBOOT this node (migrate guests off first: docs/06), then verify:"
echo "  lspci -nnks ${ADDR}      # 'Kernel driver in use: vfio-pci'"
echo "  find /sys/kernel/iommu_groups/ -type l | wc -l    # > 0 (groups exist)"
echo "Then create the AI VM on THIS node: 16-create-ai-vm.sh ${ADDR}"
