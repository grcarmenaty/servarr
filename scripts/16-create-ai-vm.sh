#!/usr/bin/env bash
# Create the AI VM with GPU passthrough (docs/16). Run ON THE GPU NODE,
# after 26-prepare-gpu-passthrough.sh + reboot.
#
#   bash 16-create-ai-vm.sh 01:00        # the GPU's PCI address (no .0)
#
# The VM is pinned to this node by the passthrough — deliberately NOT
# HA-enrolled (a GPU VM can't migrate).

source "$(dirname "$0")/lib.sh"
require_root
require_pve

GPU="${1:-}"
[[ "$GPU" =~ ^[0-9a-f]{2}:[0-9a-f]{2}$ ]] || die "usage: $0 <pci-addr like 01:00>"

# hard guard: the AI VM belongs on the P40 node (GPU_NODE in cluster.env)
if [[ -n "${GPU_NODE:-}" && "$(hostname)" != "$GPU_NODE" ]]; then
    die "this is $(hostname) — the AI VM must be created on ${GPU_NODE} (GPU_NODE in cluster.env).
       SSH there and run this script again. (If the P40 genuinely lives here,
       update GPU_NODE in cluster.env first.)"
fi

lspci -s "$GPU" >/dev/null 2>&1 || die "no device at ${GPU} — run this on the GPU node"
DRIVER="$(lspci -nnks "$GPU" | sed -n 's/.*Kernel driver in use: //p' | head -1)"
[[ "$DRIVER" == "vfio-pci" ]] || die "GPU at ${GPU} is bound to '${DRIVER:-nothing}', not vfio-pci — run 26-prepare-gpu-passthrough.sh + reboot first"

IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/$(basename "$IMG_URL")"

[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet"
! qm status "${AI_VMID}" >/dev/null 2>&1 || die "VMID ${AI_VMID} already exists"

KEYFILE=""
for k in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    [[ -f "$k" ]] && { KEYFILE="$k"; break; }
done
[[ -n "$KEYFILE" ]] || { ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519; KEYFILE=/root/.ssh/id_ed25519.pub; }

if [[ ! -f "$IMG" ]]; then
    log "Downloading Debian 13 cloud image"
    wget -q --show-progress -O "${IMG}.part" "$IMG_URL"
    mv "${IMG}.part" "$IMG"
fi

log "Creating VM ${AI_VMID} (${AI_NAME}): ${AI_CORES} cores, $((AI_MEMORY_MB / 1024)) GB RAM, GPU ${GPU}"
qm create "${AI_VMID}" \
    --name "${AI_NAME}" \
    --memory "${AI_MEMORY_MB}" \
    --balloon 0 \
    --cores "${AI_CORES}" \
    --cpu host \
    --net0 "virtio,bridge=vmbr0" \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${VM_POOL}:1,efitype=4m,pre-enrolled-keys=0" \
    --scsihw virtio-scsi-single \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --ostype l26 \
    --serial0 socket --vga serial0

qm set "${AI_VMID}" --scsi0 "${VM_POOL}:0,import-from=${IMG},discard=on,iothread=1"
qm disk resize "${AI_VMID}" scsi0 "${AI_ROOT_GB}G"

log "Adding ${AI_DATA_GB}G model disk (thin, excluded from backups — models re-download)"
qm set "${AI_VMID}" --scsi1 "${VM_POOL}:${AI_DATA_GB},discard=on,iothread=1,backup=0"

log "Attaching GPU ${GPU} (all functions, PCIe)"
qm set "${AI_VMID}" --hostpci0 "0000:${GPU},pcie=1"

qm set "${AI_VMID}" \
    --ide2 "${VM_POOL}:cloudinit" \
    --boot order=scsi0 \
    --ciuser "${CLOUD_USER}" \
    --sshkeys "${KEYFILE}" \
    --ipconfig0 "ip=${AI_IP}/24,gw=${LAN_GATEWAY}" \
    --nameserver "${LAN_DNS}" \
    --ciupgrade 1

qm start "${AI_VMID}"

echo
log "VM created (pinned to $(hostname) — not HA). Give cloud-init a minute, then:"
echo "  scp -r ai ${CLOUD_USER}@${AI_IP}:~"
echo "  ssh ${CLOUD_USER}@${AI_IP}"
echo "  cd ai && sudo bash bootstrap.sh      # installs driver, asks to reboot"
echo "  # after the VM reboots:"
echo "  cd ai && sudo bash bootstrap.sh      # second pass: docker + stack"
echo
echo "Full walkthrough: docs/16-ai-assistant.md"
