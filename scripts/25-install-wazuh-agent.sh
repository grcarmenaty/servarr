#!/usr/bin/env bash
# Install + enroll the Wazuh agent on this machine. Deliberately standalone
# (no cluster.env) so the SAME script works on Proxmox nodes, VMs, and LXCs:
#
#   bash 25-install-wazuh-agent.sh                # manager = 10.0.0.26
#   bash 25-install-wazuh-agent.sh 10.0.0.26      # explicit manager IP
#
# Idempotent. Debian/Proxmox only (apt).

set -euo pipefail
log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

MANAGER="${1:-10.0.0.26}"
export DEBIAN_FRONTEND=noninteractive

if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
    log "wazuh-agent already running (manager: $(grep -oPm1 '(?<=<address>)[^<]+' /var/ossec/etc/ossec.conf 2>/dev/null || echo '?'))"
    exit 0
fi

log "Adding Wazuh apt repository"
apt-get update
apt-get install -y curl gnupg apt-transport-https
mkdir -p /etc/apt/keyrings
curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
    | gpg --dearmor -o /etc/apt/keyrings/wazuh.gpg
echo "deb [signed-by=/etc/apt/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list
apt-get update

log "Installing agent, enrolling with manager ${MANAGER}"
WAZUH_MANAGER="$MANAGER" apt-get install -y wazuh-agent

systemctl daemon-reload
systemctl enable --now wazuh-agent

# hold the package: agents should be upgraded deliberately, in step with the manager
apt-mark hold wazuh-agent >/dev/null

log "Agent running. It should appear in the dashboard (Agents) within a minute."
