#!/usr/bin/env bash
# Create the servarr media-stack VM from a Debian cloud image (docs/08).
# Run ONCE, on any cluster node, after Ceph storage exists.
#
#   bash 10-create-servarr-vm.sh          # create + start
#   bash 10-create-servarr-vm.sh --ha     # also enroll in HA
#
# Settings come from cluster.env (SERVARR_* variables).

source "$(dirname "$0")/lib.sh"
require_root
require_pve

IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/$(basename "$IMG_URL")"

[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet — the VM disks live on ${VM_POOL}"
pvesm status --storage "${VM_POOL}" >/dev/null 2>&1 || die "storage '${VM_POOL}' not found"
! qm status "${SERVARR_VMID}" >/dev/null 2>&1 || die "VMID ${SERVARR_VMID} already exists"

# SSH key for cloud-init login
KEYFILE=""
for k in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    [[ -f "$k" ]] && { KEYFILE="$k"; break; }
done
if [[ -z "$KEYFILE" ]]; then
    log "No SSH key on this node — generating one"
    ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
    KEYFILE=/root/.ssh/id_ed25519.pub
fi

if [[ ! -f "$IMG" ]]; then
    log "Downloading Debian 13 cloud image"
    wget -q --show-progress -O "${IMG}.part" "$IMG_URL"
    mv "${IMG}.part" "$IMG"
fi

log "Creating VM ${SERVARR_VMID} (${SERVARR_NAME}): ${SERVARR_CORES} cores, $((SERVARR_MEMORY_MB / 1024)) GB RAM"
qm create "${SERVARR_VMID}" \
    --name "${SERVARR_NAME}" \
    --memory "${SERVARR_MEMORY_MB}" \
    --cores "${SERVARR_CORES}" \
    --cpu host \
    --net0 "virtio,bridge=vmbr0" \
    --scsihw virtio-scsi-single \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --ostype l26 \
    --serial0 socket --vga serial0

log "Importing root disk onto ${VM_POOL} and resizing to ${SERVARR_ROOT_GB}G"
qm set "${SERVARR_VMID}" --scsi0 "${VM_POOL}:0,import-from=${IMG},discard=on,iothread=1"
qm disk resize "${SERVARR_VMID}" scsi0 "${SERVARR_ROOT_GB}G"

log "Adding ${SERVARR_DATA_GB}G media data disk (thin, excluded from vzdump backups)"
qm set "${SERVARR_VMID}" --scsi1 "${VM_POOL}:${SERVARR_DATA_GB},discard=on,iothread=1,backup=0"

log "Configuring cloud-init: user=${SERVARR_USER}, ip=${SERVARR_IP}/24, gw=${LAN_GATEWAY}"
qm set "${SERVARR_VMID}" \
    --ide2 "${VM_POOL}:cloudinit" \
    --boot order=scsi0 \
    --ciuser "${SERVARR_USER}" \
    --sshkeys "${KEYFILE}" \
    --ipconfig0 "ip=${SERVARR_IP}/24,gw=${LAN_GATEWAY}" \
    --nameserver "${LAN_DNS}" \
    --ciupgrade 1

log "Starting VM"
qm start "${SERVARR_VMID}"

if [[ "${1:-}" == "--ha" ]]; then
    log "Enrolling in HA"
    ha-manager add "vm:${SERVARR_VMID}" --state started
fi

echo
log "VM created. Give cloud-init a minute on first boot, then:"
echo "  ssh ${SERVARR_USER}@${SERVARR_IP}"
echo "  # copy this repo's servarr/ directory to the VM, then inside it:"
echo "  sudo bash bootstrap.sh"
echo
echo "Full walkthrough: docs/08-servarr-stack.md"
