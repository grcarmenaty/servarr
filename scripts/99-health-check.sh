#!/usr/bin/env bash
# One-shot cluster health overview. Run on any node, any time.
#
#   bash 99-health-check.sh

source "$(dirname "$0")/lib.sh"
require_root
require_pve

section() { echo; echo -e "\e[1;36m── $* ──────────────────────────────\e[0m"; }

FAIL=0

section "Node: $(hostname) — $(pveversion)"

section "Time sync"
if chronyc tracking 2>/dev/null | grep -E 'System time|Leap status'; then :; else
    warn "chrony not responding"; FAIL=1
fi

section "Proxmox cluster quorum"
if pvecm status 2>/dev/null | grep -E 'Nodes:|Quorate:'; then
    pvecm status | grep -q 'Quorate:.*Yes' || { warn "cluster NOT quorate"; FAIL=1; }
else
    warn "no cluster configured on this node"; FAIL=1
fi

section "Node reachability"
for i in "${!NODE_NAMES[@]}"; do
    if ping -c1 -W2 "${NODE_IPS[$i]}" >/dev/null 2>&1; then
        echo "  ${NODE_NAMES[$i]} (${NODE_IPS[$i]})  OK"
    else
        echo "  ${NODE_NAMES[$i]} (${NODE_IPS[$i]})  UNREACHABLE"; FAIL=1
    fi
done

if [[ -f /etc/pve/ceph.conf ]]; then
    section "Ceph status"
    ceph -s || FAIL=1
    ceph health | grep -q HEALTH_OK || { warn "Ceph not HEALTH_OK — see 'ceph health detail'"; FAIL=1; }

    section "Ceph capacity"
    ceph df | head -n 8

    section "OSD tree"
    ceph osd tree
else
    section "Ceph"
    echo "  not configured on this node yet"
fi

section "Local resources"
free -h | sed -n '1,2p'
df -h / | sed -n '1,2p'

echo
if [[ $FAIL -eq 0 ]]; then
    log "All checks passed."
else
    warn "One or more checks failed — see above."
    exit 1
fi
