#!/usr/bin/env bash
# Create the Wazuh SIEM VM (docs/14). Run ONCE, on any cluster node.
#
#   bash 15-create-wazuh-vm.sh          # create + start
#   bash 15-create-wazuh-vm.sh --ha     # also enroll in HA

source "$(dirname "$0")/lib.sh"
require_root
require_pve

IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/$(basename "$IMG_URL")"

[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet"
! qm status "${WAZUH_VMID}" >/dev/null 2>&1 || die "VMID ${WAZUH_VMID} already exists"

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

log "Creating VM ${WAZUH_VMID} (${WAZUH_NAME}): ${WAZUH_CORES} cores, $((WAZUH_MEMORY_MB / 1024)) GB RAM"
qm create "${WAZUH_VMID}" \
    --name "${WAZUH_NAME}" \
    --memory "${WAZUH_MEMORY_MB}" \
    --cores "${WAZUH_CORES}" \
    --cpu host \
    --net0 "virtio,bridge=vmbr0" \
    --scsihw virtio-scsi-single \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --ostype l26 \
    --serial0 socket --vga serial0

qm set "${WAZUH_VMID}" --scsi0 "${VM_POOL}:0,import-from=${IMG},discard=on,iothread=1"
qm disk resize "${WAZUH_VMID}" scsi0 "${WAZUH_ROOT_GB}G"

log "Adding ${WAZUH_DATA_GB}G data disk (docker data-root / indexer storage)"
qm set "${WAZUH_VMID}" --scsi1 "${VM_POOL}:${WAZUH_DATA_GB},discard=on,iothread=1"

qm set "${WAZUH_VMID}" \
    --ide2 "${VM_POOL}:cloudinit" \
    --boot order=scsi0 \
    --ciuser "${CLOUD_USER}" \
    --sshkeys "${KEYFILE}" \
    --ipconfig0 "ip=${WAZUH_IP}/24,gw=${LAN_GATEWAY}" \
    --nameserver "${LAN_DNS}" \
    --ciupgrade 1

qm start "${WAZUH_VMID}"

[[ "${1:-}" == "--ha" ]] && ha-manager add "vm:${WAZUH_VMID}" --state started

echo
log "VM created. Give cloud-init a minute, then:"
echo "  scp -r wazuh ${CLOUD_USER}@${WAZUH_IP}:~"
echo "  ssh ${CLOUD_USER}@${WAZUH_IP}"
echo "  cd wazuh && sudo WAZUH_VERSION=${WAZUH_VERSION} bash bootstrap.sh"
echo
echo "Then enroll agents everywhere: scripts/25-install-wazuh-agent.sh (docs/14)"
