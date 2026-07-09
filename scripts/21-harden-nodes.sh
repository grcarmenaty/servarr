#!/usr/bin/env bash
# Node hardening: fail2ban jails for SSH and the Proxmox web UI.
# Run on EVERY node. Idempotent.
#
#   bash 21-harden-nodes.sh

source "$(dirname "$0")/lib.sh"
require_root
require_pve

log "Installing fail2ban"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y fail2ban

log "Configuring jails (sshd + Proxmox web UI login)"
cat > /etc/fail2ban/jail.d/homelab.conf <<'EOF'
[DEFAULT]
# never ban the cluster's own networks
ignoreip = 127.0.0.1/8 10.0.0.0/24 10.10.10.0/24 10.8.0.0/24
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd

[proxmox]
enabled = true
port = https,http,8006
filter = proxmox
backend = systemd
maxretry = 3
EOF

cat > /etc/fail2ban/filter.d/proxmox.conf <<'EOF'
[Definition]
failregex = pvedaemon\[.*authentication failure; rhost=<HOST> user=.* msg=.*
journalmatch = _SYSTEMD_UNIT=pvedaemon.service
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 2
fail2ban-client status

echo
log "Done. Check a jail anytime:  fail2ban-client status proxmox"
log "Note: ignoreip covers the LAN/mesh/VPN — bans only ever hit strangers."
echo
echo "Also recommended (manual, once you're sure your SSH keys work):"
echo "  disable password SSH on nodes: 'PasswordAuthentication no' in"
echo "  /etc/ssh/sshd_config.d/hardening.conf && systemctl reload sshd"
