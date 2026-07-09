#!/usr/bin/env bash
# Form the Proxmox cluster.
#
#   On the FIRST node:   bash 02-create-cluster.sh create
#   On the OTHER nodes:  bash 02-create-cluster.sh join
#
# Join nodes one at a time; each join prompts for the first node's
# root password and TLS fingerprint confirmation.

source "$(dirname "$0")/lib.sh"
require_root
require_pve

MODE="${1:-}"
FIRST_IP="${NODE_IPS[0]}"

preflight() {
    # all nodes must resolve and answer, on the LAN and (if configured) the mesh
    for i in "${!NODE_NAMES[@]}"; do
        getent hosts "${NODE_NAMES[$i]}" >/dev/null \
            || die "${NODE_NAMES[$i]} not in /etc/hosts — run 01-post-install.sh first"
        ping -c1 -W2 "${NODE_IPS[$i]}" >/dev/null \
            || die "cannot ping ${NODE_NAMES[$i]} (${NODE_IPS[$i]}) on the LAN"
        if [[ "${#CEPH_IPS[@]}" -gt 0 ]]; then
            ping -c1 -W2 "${CEPH_IPS[$i]}" >/dev/null \
                || die "cannot ping ${NODE_NAMES[$i]} (${CEPH_IPS[$i]}) on the Ceph mesh — run 00-ceph-mesh-network.sh everywhere first"
        fi
    done
    log "preflight OK — all nodes reachable on all networks"
}

# corosync link args for the node at index $1: link0 = LAN, link1 = mesh
link_args() {
    local i="$1" args=(--link0 "${NODE_IPS[$i]}")
    [[ "${#CEPH_IPS[@]}" -gt 0 ]] && args+=(--link1 "${CEPH_IPS[$i]}")
    echo "${args[@]}"
}

case "$MODE" in
create)
    [[ "$(hostname)" == "${NODE_NAMES[0]}" ]] \
        || die "'create' should run on ${NODE_NAMES[0]} (this is $(hostname))"
    if pvecm status >/dev/null 2>&1; then
        log "cluster already exists:"; pvecm status; exit 0
    fi
    preflight
    log "Creating cluster '${CLUSTER_NAME}' (corosync link0=LAN, link1=mesh)"
    # shellcheck disable=SC2046
    pvecm create "${CLUSTER_NAME}" $(link_args 0)
    if ! grep -q '^migration:' /etc/pve/datacenter.cfg 2>/dev/null; then
        echo "migration: secure,network=${CEPH_NETWORK}" >> /etc/pve/datacenter.cfg
        log "live migration pinned to ${CEPH_NETWORK} (datacenter.cfg)"
    fi
    pvecm status
    echo
    log "Now run 'bash 02-create-cluster.sh join' on the other nodes, one at a time."
    ;;
join)
    [[ "$(hostname)" != "${NODE_NAMES[0]}" ]] \
        || die "'join' runs on the other nodes, not ${NODE_NAMES[0]}"
    if pvecm status >/dev/null 2>&1; then
        log "this node is already in a cluster:"; pvecm status; exit 0
    fi
    preflight
    if [[ -n "$(ls -A /etc/pve/qemu-server 2>/dev/null)" || -n "$(ls -A /etc/pve/lxc 2>/dev/null)" ]]; then
        die "this node has guests — a joining node must be empty (docs/04-cluster.md)"
    fi
    IDX="$(this_node_index)"
    [[ -n "$IDX" ]] || die "hostname $(hostname) not in NODE_NAMES (cluster.env)"
    log "Joining cluster via ${FIRST_IP} (you'll be asked for its root password)"
    # shellcheck disable=SC2046
    pvecm add "${FIRST_IP}" $(link_args "$IDX")
    pvecm status
    ;;
*)
    die "usage: $0 create|join"
    ;;
esac
