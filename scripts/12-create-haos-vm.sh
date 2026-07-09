#!/usr/bin/env bash
# Create the Home Assistant OS VM (optional — smart home hub, docs/09).
# Run ONCE, on any cluster node:
#
#   bash 12-create-haos-vm.sh          # create + start
#   bash 12-create-haos-vm.sh --ha     # also enroll in HA
#
# HAOS ships as a ready-made disk image (no installer, no cloud-init). It
# takes its IP via DHCP — reserve HAOS_IP for its MAC in the router, or set
# a static IP later in Home Assistant (Settings → System → Network).

source "$(dirname "$0")/lib.sh"
require_root
require_pve

URL="https://github.com/home-assistant/operating-system/releases/download/${HAOS_VERSION}/haos_ova-${HAOS_VERSION}.qcow2.xz"
IMG="/var/lib/vz/template/haos_ova-${HAOS_VERSION}.qcow2"

[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet"
! qm status "${HAOS_VMID}" >/dev/null 2>&1 || die "VMID ${HAOS_VMID} already exists"

if [[ ! -f "$IMG" ]]; then
    log "Downloading Home Assistant OS ${HAOS_VERSION}"
    wget -q --show-progress -O "${IMG}.xz.part" "$URL" \
        || die "download failed — check HAOS_VERSION in cluster.env against https://github.com/home-assistant/operating-system/releases"
    mv "${IMG}.xz.part" "${IMG}.xz"
    unxz "${IMG}.xz"
fi

log "Creating VM ${HAOS_VMID} (haos): 2 cores, 4 GB RAM, UEFI"
qm create "${HAOS_VMID}" \
    --name haos \
    --memory 4096 \
    --cores 2 \
    --cpu host \
    --net0 "virtio,bridge=vmbr0" \
    --bios ovmf \
    --machine q35 \
    --efidisk0 "${VM_POOL}:1,efitype=4m,pre-enrolled-keys=0" \
    --scsihw virtio-scsi-single \
    --agent enabled=1 \
    --ostype l26 \
    --onboot 1

log "Importing HAOS disk onto ${VM_POOL}"
qm set "${HAOS_VMID}" --scsi0 "${VM_POOL}:0,import-from=${IMG},discard=on,iothread=1"
qm set "${HAOS_VMID}" --boot order=scsi0

log "Starting VM"
qm start "${HAOS_VMID}"

if [[ "${1:-}" == "--ha" ]]; then
    ha-manager add "vm:${HAOS_VMID}" --state started
fi

echo
log "HAOS is booting (first boot takes a few minutes)."
echo "  1. Reserve ${HAOS_IP} for this VM's MAC in the router's DHCP"
echo "     (MAC: $(qm config "${HAOS_VMID}" | sed -n 's/^net0.*virtio=\([^,]*\).*/\1/p'))"
echo "  2. Onboarding: http://${HAOS_IP}:8123 (or http://homeassistant.local:8123)"
