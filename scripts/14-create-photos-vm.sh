#!/usr/bin/env bash
# Create the photos VM (Immich — self-hosted Google Photos, docs/11).
# Run ONCE, on any cluster node, after Ceph storage exists.
#
#   bash 14-create-photos-vm.sh          # create + start
#   bash 14-create-photos-vm.sh --ha     # also enroll in HA
#
# Settings come from cluster.env (PHOTOS_*). The photo library disk IS
# included in vzdump backups (photos are not re-acquirable).

source "$(dirname "$0")/lib.sh"
require_root
require_pve

IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/$(basename "$IMG_URL")"

[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet — the VM disks live on ${VM_POOL}"
if qm status "${PHOTOS_VMID}" >/dev/null 2>&1; then
    log "VM ${PHOTOS_VMID} (${PHOTOS_NAME}) already exists — nothing to do (idempotent skip)"
    exit 0
fi

KEYFILE=""
for k in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    [[ -f "$k" ]] && { KEYFILE="$k"; break; }
done
if [[ -z "$KEYFILE" ]]; then
    ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
    KEYFILE=/root/.ssh/id_ed25519.pub
fi

if [[ ! -f "$IMG" ]]; then
    log "Downloading Debian 13 cloud image"
    wget -q --show-progress -O "${IMG}.part" "$IMG_URL"
    mv "${IMG}.part" "$IMG"
fi

log "Creating VM ${PHOTOS_VMID} (${PHOTOS_NAME}): ${PHOTOS_CORES} cores, $((PHOTOS_MEMORY_MB / 1024)) GB RAM"
qm create "${PHOTOS_VMID}" \
    --name "${PHOTOS_NAME}" \
    --memory "${PHOTOS_MEMORY_MB}" \
    --cores "${PHOTOS_CORES}" \
    --cpu host \
    --net0 "virtio,bridge=vmbr0" \
    --scsihw virtio-scsi-single \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --ostype l26 \
    --serial0 socket --vga serial0

qm set "${PHOTOS_VMID}" --scsi0 "${VM_POOL}:0,import-from=${IMG},discard=on,iothread=1"
qm disk resize "${PHOTOS_VMID}" scsi0 "${PHOTOS_ROOT_GB}G"

log "Adding ${PHOTOS_DATA_GB}G photo library disk (thin, INCLUDED in backups)"
qm set "${PHOTOS_VMID}" --scsi1 "${VM_POOL}:${PHOTOS_DATA_GB},discard=on,iothread=1"

qm set "${PHOTOS_VMID}" \
    --ide2 "${VM_POOL}:cloudinit" \
    --boot order=scsi0 \
    --ciuser "${CLOUD_USER}" \
    --sshkeys "${KEYFILE}" \
    --ipconfig0 "ip=${PHOTOS_IP}/24,gw=${LAN_GATEWAY}" \
    --nameserver "${LAN_DNS}" \
    --ciupgrade 1

qm start "${PHOTOS_VMID}"

if [[ "${1:-}" == "--ha" ]]; then
    ha-manager add "vm:${PHOTOS_VMID}" --state started
fi

echo
log "VM created. Give cloud-init a minute, then:"
echo "  scp -r photos ${CLOUD_USER}@${PHOTOS_IP}:~"
echo "  ssh ${CLOUD_USER}@${PHOTOS_IP}"
echo "  cd photos && sudo bash bootstrap.sh"
echo
echo "Full walkthrough: docs/11-photos.md"
