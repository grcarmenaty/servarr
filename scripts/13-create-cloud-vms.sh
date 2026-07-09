#!/usr/bin/env bash
# Create the cloud tier (docs/10): cloud-data (Postgres/Redis/NFS/Firefly)
# plus TWO stateless Nextcloud app VMs (cloud1, cloud2) that Caddy
# load-balances. Run ONCE, on any cluster node, after Ceph storage exists.
#
#   bash 13-create-cloud-vms.sh          # create + start all three
#   bash 13-create-cloud-vms.sh --ha     # also enroll each in HA
#
# Settings come from cluster.env (CLOUDDATA_* / CLOUD_APP_*). After this,
# run 20-enable-ha.sh to add the anti-affinity rule keeping cloud1 and
# cloud2 on different nodes.

source "$(dirname "$0")/lib.sh"
require_root
require_pve

HA_FLAG="${1:-}"
IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/$(basename "$IMG_URL")"

[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet — the VM disks live on ${VM_POOL}"
pvesm status --storage "${VM_POOL}" >/dev/null 2>&1 || die "storage '${VM_POOL}' not found"

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

# create_vm <vmid> <name> <ip> <cores> <mem_mb> <root_gb> [data_gb]
create_vm() {
    local vmid="$1" name="$2" ip="$3" cores="$4" mem="$5" root_gb="$6" data_gb="${7:-}"

    if qm status "$vmid" >/dev/null 2>&1; then
        log "${name}: VMID ${vmid} already exists — skipping"
        return
    fi

    log "${name}: creating VM ${vmid} (${cores} cores, $((mem / 1024)) GB RAM, ${ip})"
    qm create "$vmid" \
        --name "$name" \
        --memory "$mem" \
        --cores "$cores" \
        --cpu host \
        --net0 "virtio,bridge=vmbr0" \
        --scsihw virtio-scsi-single \
        --agent enabled=1,fstrim_cloned_disks=1 \
        --ostype l26 \
        --serial0 socket --vga serial0

    qm set "$vmid" --scsi0 "${VM_POOL}:0,import-from=${IMG},discard=on,iothread=1"
    qm disk resize "$vmid" scsi0 "${root_gb}G"

    if [[ -n "$data_gb" ]]; then
        log "${name}: adding ${data_gb}G data disk (thin, INCLUDED in backups)"
        qm set "$vmid" --scsi1 "${VM_POOL}:${data_gb},discard=on,iothread=1"
    fi

    qm set "$vmid" \
        --ide2 "${VM_POOL}:cloudinit" \
        --boot order=scsi0 \
        --ciuser "${CLOUD_USER}" \
        --sshkeys "${KEYFILE}" \
        --ipconfig0 "ip=${ip}/24,gw=${LAN_GATEWAY}" \
        --nameserver "${LAN_DNS}" \
        --ciupgrade 1

    qm start "$vmid"

    if [[ "$HA_FLAG" == "--ha" ]]; then
        ha-manager add "vm:${vmid}" --state started
    fi
}

create_vm "${CLOUDDATA_VMID}" "${CLOUDDATA_NAME}" "${CLOUDDATA_IP}" \
    "${CLOUDDATA_CORES}" "${CLOUDDATA_MEMORY_MB}" "${CLOUDDATA_ROOT_GB}" "${CLOUDDATA_DATA_GB}"

for i in "${!CLOUD_APP_VMIDS[@]}"; do
    create_vm "${CLOUD_APP_VMIDS[$i]}" "${CLOUD_APP_NAMES[$i]}" "${CLOUD_APP_IPS[$i]}" \
        "${CLOUD_APP_CORES}" "${CLOUD_APP_MEMORY_MB}" "${CLOUD_APP_ROOT_GB}"
done

echo
log "Cloud tier created. Bootstrap order (docs/10-cloud-stack.md):"
echo "  1. cloud-data:  scp -r cloud/data ${CLOUD_USER}@${CLOUDDATA_IP}:~/cloud-data"
echo "                  ssh in, 'sudo bash cloud-data/bootstrap.sh', docker compose up -d"
echo "  2. cloud1:      scp -r cloud/app  ${CLOUD_USER}@${CLOUD_APP_IPS[0]}:~/cloud-app"
echo "                  bootstrap, paste passwords into .env, docker compose up -d --build"
echo "                  → wait until http://${CLOUD_APP_IPS[0]}:8080 finishes installing"
echo "  3. cloud2:      same as cloud1 (${CLOUD_APP_IPS[1]})"
echo "  4. on a node:   bash scripts/20-enable-ha.sh   # HA everything + anti-affinity"
