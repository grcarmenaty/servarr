#!/usr/bin/env bash
# Create the cloud VM (Nextcloud + Firefly III — docs/10) from a Debian
# cloud image. Run ONCE, on any cluster node, after Ceph storage exists.
#
#   bash 13-create-cloud-vm.sh          # create + start
#   bash 13-create-cloud-vm.sh --ha     # also enroll in HA
#
# Settings come from cluster.env (CLOUD_* variables). Unlike the servarr
# media disk, the cloud data disk (personal files) IS included in backups.

source "$(dirname "$0")/lib.sh"
require_root
require_pve

IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/$(basename "$IMG_URL")"

[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet — the VM disks live on ${VM_POOL}"
pvesm status --storage "${VM_POOL}" >/dev/null 2>&1 || die "storage '${VM_POOL}' not found"
! qm status "${CLOUD_VMID}" >/dev/null 2>&1 || die "VMID ${CLOUD_VMID} already exists"

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

log "Creating VM ${CLOUD_VMID} (${CLOUD_NAME}): ${CLOUD_CORES} cores, $((CLOUD_MEMORY_MB / 1024)) GB RAM"
qm create "${CLOUD_VMID}" \
    --name "${CLOUD_NAME}" \
    --memory "${CLOUD_MEMORY_MB}" \
    --cores "${CLOUD_CORES}" \
    --cpu host \
    --net0 "virtio,bridge=vmbr0" \
    --scsihw virtio-scsi-single \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --ostype l26 \
    --serial0 socket --vga serial0

log "Importing root disk onto ${VM_POOL} and resizing to ${CLOUD_ROOT_GB}G"
qm set "${CLOUD_VMID}" --scsi0 "${VM_POOL}:0,import-from=${IMG},discard=on,iothread=1"
qm disk resize "${CLOUD_VMID}" scsi0 "${CLOUD_ROOT_GB}G"

log "Adding ${CLOUD_DATA_GB}G data disk (thin, INCLUDED in vzdump backups)"
qm set "${CLOUD_VMID}" --scsi1 "${VM_POOL}:${CLOUD_DATA_GB},discard=on,iothread=1"

log "Configuring cloud-init: user=${CLOUD_USER}, ip=${CLOUD_IP}/24, gw=${LAN_GATEWAY}"
qm set "${CLOUD_VMID}" \
    --ide2 "${VM_POOL}:cloudinit" \
    --boot order=scsi0 \
    --ciuser "${CLOUD_USER}" \
    --sshkeys "${KEYFILE}" \
    --ipconfig0 "ip=${CLOUD_IP}/24,gw=${LAN_GATEWAY}" \
    --nameserver "${LAN_DNS}" \
    --ciupgrade 1

log "Starting VM"
qm start "${CLOUD_VMID}"

if [[ "${1:-}" == "--ha" ]]; then
    log "Enrolling in HA"
    ha-manager add "vm:${CLOUD_VMID}" --state started
fi

echo
log "VM created. Give cloud-init a minute on first boot, then:"
echo "  ssh ${CLOUD_USER}@${CLOUD_IP}"
echo "  # copy this repo's cloud/ directory to the VM, then inside it:"
echo "  sudo bash bootstrap.sh"
echo
echo "Full walkthrough: docs/10-cloud-stack.md"
