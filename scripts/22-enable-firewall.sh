#!/usr/bin/env bash
# Enable the Proxmox cluster firewall (host-level, defense in depth).
# Run ONCE, on any node — /etc/pve is cluster-wide.
#
#   bash 22-enable-firewall.sh
#
# What it does: default-DROP inbound ON THE NODES, allowing the Ceph mesh,
# intra-cluster traffic, and management (8006/22/ntopng/ICMP) from the LAN.
# Guest (VM/LXC) traffic is NOT filtered — per-guest firewalls stay off
# unless you enable them on a NIC yourself.
#
# LOCKOUT RECOVERY (keep this in mind before running): from any node's
# physical/serial console:  pve-firewall stop
# then edit /etc/pve/firewall/cluster.fw (set 'enable: 0') and investigate.

source "$(dirname "$0")/lib.sh"
require_root
require_pve

FW=/etc/pve/firewall/cluster.fw

pvecm status >/dev/null 2>&1 || die "cluster not formed yet"
[[ ! -f "$FW" ]] && log "creating ${FW}" || die "${FW} already exists — edit it via the GUI (Datacenter → Firewall) instead of re-running this"

NODE_RULES=""
for ip in "${NODE_IPS[@]}"; do
    NODE_RULES+="IN ACCEPT -source ${ip} # cluster peer (corosync link0, pveproxy, ssh)"$'\n'
done

cat > "$FW" <<EOF
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
# Ceph public network + corosync link1 + live migration — full trust
IN ACCEPT -source ${CEPH_NETWORK}
${NODE_RULES}# management from the LAN
IN ACCEPT -source ${NODE_IPS[0]%.*}.0/24 -p tcp -dport 8006 # web UI
IN ACCEPT -source ${NODE_IPS[0]%.*}.0/24 -p tcp -dport 22 # SSH
IN ACCEPT -source ${NODE_IPS[0]%.*}.0/24 -p tcp -dport 3000 # ntopng (23-install-ntopng.sh)
IN ACCEPT -p icmp # ping/diagnostics
EOF

log "Wrote ${FW}:"
sed 's/^/  /' "$FW"
echo
confirm "Enable the firewall cluster-wide now?" || {
    sed -i 's/^enable: 1/enable: 0/' "$FW"
    die "left disabled (enable: 0 in ${FW}) — flip it in the GUI when ready"
}

systemctl restart pve-firewall
pve-firewall status
log "Firewall active. Verify you can still reach the web UI and SSH NOW,"
log "while you have this shell open. Recovery: 'pve-firewall stop' on a console."
