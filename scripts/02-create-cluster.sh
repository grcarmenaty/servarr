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
    # all nodes must resolve and answer
    for i in "${!NODE_NAMES[@]}"; do
        getent hosts "${NODE_NAMES[$i]}" >/dev/null \
            || die "${NODE_NAMES[$i]} not in /etc/hosts — run 01-post-install.sh first"
        ping -c1 -W2 "${NODE_IPS[$i]}" >/dev/null \
            || die "cannot ping ${NODE_NAMES[$i]} (${NODE_IPS[$i]})"
    done
    log "preflight OK — all nodes resolvable and reachable"
}

case "$MODE" in
create)
    [[ "$(hostname)" == "${NODE_NAMES[0]}" ]] \
        || die "'create' should run on ${NODE_NAMES[0]} (this is $(hostname))"
    if pvecm status >/dev/null 2>&1; then
        log "cluster already exists:"; pvecm status; exit 0
    fi
    preflight
    log "Creating cluster '${CLUSTER_NAME}'"
    pvecm create "${CLUSTER_NAME}"
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
    log "Joining cluster via ${FIRST_IP} (you'll be asked for its root password)"
    pvecm add "${FIRST_IP}"
    pvecm status
    ;;
*)
    die "usage: $0 create|join"
    ;;
esac
