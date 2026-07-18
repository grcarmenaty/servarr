#!/usr/bin/env bash
# Create the AI VM (Ollama + Open WebUI + Whisper/Piper — docs/16).
# CPU inference by default → a normal VM, creatable on ANY node,
# migratable, HA-enrollable.
#
#   bash 16-create-ai-vm.sh                # CPU (default, recommended)
#   bash 16-create-ai-vm.sh --gpu 01:00    # optional: GTX 960 passthrough —
#                                          # ⚠ must run ON the GPU node, after
#                                          # 26-prepare-gpu-passthrough.sh;
#                                          # pins the VM, drops HA (docs/16)

source "$(dirname "$0")/lib.sh"
require_root
require_pve

GPU=""
if [[ "${1:-}" == "--gpu" ]]; then
    GPU="${2:-}"
    [[ "$GPU" =~ ^[0-9a-f]{2}:[0-9a-f]{2}$ ]] || die "usage: $0 [--gpu <pci-addr like 01:00>]"
    if [[ -n "${GPU_NODE:-}" && "$(hostname)" != "$GPU_NODE" ]]; then
        die "GPU passthrough must run on ${GPU_NODE} (GPU_NODE in cluster.env) — this is $(hostname)"
    fi
    lspci -s "$GPU" >/dev/null 2>&1 || die "no device at ${GPU} on this node"
    DRIVER="$(lspci -nnks "$GPU" | sed -n 's/.*Kernel driver in use: //p' | head -1)"
    [[ "$DRIVER" == "vfio-pci" ]] || die "GPU at ${GPU} is bound to '${DRIVER:-nothing}', not vfio-pci — run 26-prepare-gpu-passthrough.sh + reboot first"
fi

IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/$(basename "$IMG_URL")"

[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet"
if qm status "${AI_VMID}" >/dev/null 2>&1; then
    log "VM ${AI_VMID} (${AI_NAME}) already exists — nothing to do (idempotent skip)"
    exit 0
fi

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

log "Creating VM ${AI_VMID} (${AI_NAME}): ${AI_CORES} cores, $((AI_MEMORY_MB / 1024)) GB RAM${GPU:+, GPU ${GPU}}"
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

if [[ -n "$GPU" ]]; then
    log "Attaching GPU ${GPU} — VM is now PINNED to $(hostname); do not HA-enroll it"
    qm set "${AI_VMID}" --hostpci0 "0000:${GPU},pcie=1"
fi

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
log "VM created. Give cloud-init a minute, then:"
echo "  scp -r ai ${CLOUD_USER}@${AI_IP}:~"
echo "  ssh ${CLOUD_USER}@${AI_IP}"
echo "  cd ai && sudo bash bootstrap.sh"
[[ -n "$GPU" ]] && echo "  (GPU path: bootstrap will install the driver and ask for one VM reboot)"
echo
echo "HA: 20-enable-ha.sh auto-enrolls this VM only when it has no GPU attached."
echo "Full walkthrough: docs/16-ai-assistant.md"
