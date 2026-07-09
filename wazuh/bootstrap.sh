#!/usr/bin/env bash
# One-time setup inside the Wazuh VM: Docker (data-root on the big disk),
# kernel tuning for the indexer, and Wazuh's OFFICIAL single-node compose
# (cloned at a pinned tag — Wazuh pins its own image versions). Idempotent.
#
#   sudo WAZUH_VERSION=4.14.6 bash bootstrap.sh [data-disk]

set -euo pipefail
cd "$(dirname "$0")"

log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

DATA_DISK="${1:-/dev/sdb}"
WAZUH_VERSION="${WAZUH_VERSION:-4.14.6}"
LOGIN_USER="${SUDO_USER:-cloud}"

# ── 1. Data disk mounted as the docker data-root ─────────────────────────
[[ -b "$DATA_DISK" ]] || die "data disk ${DATA_DISK} not found"
ROOT_DISK="/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -n1)"
[[ "$DATA_DISK" != "$ROOT_DISK" ]] || die "${DATA_DISK} is the OS disk"

if ! blkid "$DATA_DISK" >/dev/null 2>&1; then
    log "Formatting ${DATA_DISK} as XFS"
    apt-get update && apt-get install -y xfsprogs
    mkfs.xfs "$DATA_DISK"
fi
UUID="$(blkid -s UUID -o value "$DATA_DISK")"
grep -q "$UUID" /etc/fstab || {
    mkdir -p /var/lib/docker
    echo "UUID=${UUID} /var/lib/docker xfs defaults,noatime 0 2" >> /etc/fstab
}
mountpoint -q /var/lib/docker || { systemctl daemon-reload; mount /var/lib/docker; }

# ── 2. Docker ────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker from download.docker.com"
    apt-get update
    apt-get install -y ca-certificates curl git
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
usermod -aG docker "$LOGIN_USER" 2>/dev/null || true

# ── 3. Kernel requirement for the indexer (OpenSearch) ───────────────────
log "Setting vm.max_map_count for the Wazuh indexer"
echo 'vm.max_map_count = 262144' > /etc/sysctl.d/99-wazuh.conf
sysctl -p /etc/sysctl.d/99-wazuh.conf

# ── 4. Official single-node deployment ───────────────────────────────────
if [[ ! -d wazuh-docker ]]; then
    log "Cloning wazuh-docker v${WAZUH_VERSION}"
    apt-get install -y git
    git clone -b "v${WAZUH_VERSION}" --depth 1 https://github.com/wazuh/wazuh-docker.git
    chown -R "$LOGIN_USER:$LOGIN_USER" wazuh-docker
else
    log "wazuh-docker already cloned — leaving it alone"
fi

cd wazuh-docker/single-node
if [[ ! -d config/wazuh_indexer_ssl_certs || -z "$(ls -A config/wazuh_indexer_ssl_certs 2>/dev/null)" ]]; then
    log "Generating indexer certificates"
    docker compose -f generate-indexer-certs.yml run --rm generator
fi

log "Starting Wazuh (first start takes several minutes)"
docker compose up -d

echo
log "Wazuh deploying. Dashboard: https://$(hostname -I | awk '{print $1}')  (self-signed cert)"
echo "  Default login: admin / SecretPassword — CHANGE IT, and the API/internal"
echo "  passwords too: docs/14-wazuh-siem.md links the official procedure."
echo "  Then enroll agents: scripts/25-install-wazuh-agent.sh on nodes & VMs."
