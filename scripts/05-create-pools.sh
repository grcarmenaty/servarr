#!/usr/bin/env bash
# Create the VM pool (and optional CephFS) and register them as Proxmox
# storage. Run ONCE, on any node, after all OSDs exist.
#
#   bash 05-create-pools.sh

source "$(dirname "$0")/lib.sh"
require_root
require_pve
[[ -f /etc/pve/ceph.conf ]] || die "Ceph not initialized"

OSD_COUNT="$(ceph osd stat -f json 2>/dev/null | sed -n 's/.*"num_up_osds":\([0-9]*\).*/\1/p')"
[[ -n "$OSD_COUNT" && "$OSD_COUNT" -ge 3 ]] \
    || die "need at least 3 OSDs up (found: ${OSD_COUNT:-0}) — create OSDs on every node first"

# --- RBD pool for VM disks ---------------------------------------------------
if pveceph pool ls --noborder 2>/dev/null | awk '{print $1}' | grep -qx "${VM_POOL}"; then
    log "pool '${VM_POOL}' already exists"
else
    log "Creating RBD pool '${VM_POOL}' (size=3, min_size=2) + Proxmox storage"
    pveceph pool create "${VM_POOL}" --add_storages
fi

# --- optional CephFS ---------------------------------------------------------
if [[ "${CREATE_CEPHFS}" == "yes" ]]; then
    for node in "${NODE_NAMES[@]}"; do
        if ceph mds metadata "$node" >/dev/null 2>&1; then
            log "MDS already exists on ${node}"
        else
            log "Creating MDS on ${node}"
            if [[ "$node" == "$(hostname)" ]]; then
                pveceph mds create
            else
                ssh -o BatchMode=yes "$node" pveceph mds create \
                    || warn "could not create MDS on ${node} via SSH — run 'pveceph mds create' there manually"
            fi
        fi
    done

    if ceph fs ls 2>/dev/null | grep -q "name: ${CEPHFS_NAME}"; then
        log "CephFS '${CEPHFS_NAME}' already exists"
    else
        log "Creating CephFS '${CEPHFS_NAME}' + Proxmox storage"
        pveceph fs create --name "${CEPHFS_NAME}" --add-storage
    fi
else
    log "CephFS creation skipped (CREATE_CEPHFS=no)"
fi

echo
ceph -s
echo
log "Storage registered. Check Datacenter → Storage in the web UI."
log "Next: docs/06-ha-and-vms.md — create VMs on '${VM_POOL}'."
