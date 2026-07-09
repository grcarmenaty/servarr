#!/usr/bin/env bash
# Install Ceph packages and create this node's MON + MGR.
#
#   1. Run on EVERY node:      bash 03-setup-ceph.sh install
#   2. Run on the FIRST node:  bash 03-setup-ceph.sh init
#   3. Run on EVERY node:      bash 03-setup-ceph.sh mon
#
# (install can run on all nodes in parallel; init once; mon one node at a time)

source "$(dirname "$0")/lib.sh"
require_root
require_pve

MODE="${1:-}"

case "$MODE" in
install)
    if command -v ceph >/dev/null 2>&1 && ceph --version >/dev/null 2>&1; then
        log "Ceph packages already installed: $(ceph --version)"
    else
        log "Installing Ceph (no-subscription repository)"
        pveceph install --repository no-subscription
    fi
    ;;
init)
    [[ "$(hostname)" == "${NODE_NAMES[0]}" ]] \
        || die "'init' should run once, on ${NODE_NAMES[0]}"
    if [[ -f /etc/pve/ceph.conf ]]; then
        log "Ceph already initialized (/etc/pve/ceph.conf exists)"
    else
        log "Initializing Ceph with public network ${CEPH_NETWORK}"
        pveceph init --network "${CEPH_NETWORK}"
    fi
    ;;
mon)
    [[ -f /etc/pve/ceph.conf ]] || die "run 'init' on ${NODE_NAMES[0]} first"
    host="$(hostname)"
    if ceph mon dump 2>/dev/null | grep -q "mon\.${host}\b"; then
        log "MON already exists on ${host}"
    else
        log "Creating monitor on ${host}"
        pveceph mon create
    fi
    if ceph mgr dump 2>/dev/null | grep -q "\"${host}\""; then
        log "MGR already exists on ${host}"
    else
        log "Creating manager on ${host}"
        pveceph mgr create
    fi
    echo
    ceph -s
    ;;
*)
    die "usage: $0 install|init|mon"
    ;;
esac
