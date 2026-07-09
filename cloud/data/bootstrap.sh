#!/usr/bin/env bash
# One-time setup inside the cloud-data VM: Docker, data disk, NFS exports of
# the Nextcloud html/data directories, .env with random secrets.
# Idempotent — safe to re-run.
#
#   sudo bash bootstrap.sh [data-disk]     # default data disk: /dev/sdb

set -euo pipefail
cd "$(dirname "$0")"

log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

DATA_DISK="${1:-/dev/sdb}"
DATA_MOUNT="/mnt/clouddata"
CONFIG_ROOT="/opt/cloud/config"
LOGIN_USER="${SUDO_USER:-cloud}"
# LAN IPs of the Nextcloud app VMs (cluster.env: CLOUD_APP_IPS)
APP_IPS=(10.0.0.23 10.0.0.24)

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# ── 1. Docker (official repo) ────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker from download.docker.com"
    apt-get update
    apt-get install -y ca-certificates curl openssl
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

# ── 2. Data disk ─────────────────────────────────────────────────────────
[[ -b "$DATA_DISK" ]] || die "data disk ${DATA_DISK} not found (lsblk to check; pass it as \$1)"
ROOT_DISK="/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -n1)"
[[ "$DATA_DISK" != "$ROOT_DISK" ]] || die "${DATA_DISK} is the OS disk"

if ! blkid "$DATA_DISK" >/dev/null 2>&1; then
    log "Formatting ${DATA_DISK} as XFS"
    apt-get install -y xfsprogs
    mkfs.xfs "$DATA_DISK"
fi
UUID="$(blkid -s UUID -o value "$DATA_DISK")"
if ! grep -q "$UUID" /etc/fstab; then
    mkdir -p "$DATA_MOUNT"
    echo "UUID=${UUID} ${DATA_MOUNT} xfs defaults,noatime 0 2" >> /etc/fstab
fi
mountpoint -q "$DATA_MOUNT" || { systemctl daemon-reload; mount "$DATA_MOUNT"; }

# ── 3. Nextcloud shared directories + NFS export ─────────────────────────
log "Creating Nextcloud shared directories (html = code+config, data = files)"
mkdir -p "$DATA_MOUNT/nextcloud/html" "$DATA_MOUNT/nextcloud/data" "$CONFIG_ROOT"
chown -R 33:33 "$DATA_MOUNT/nextcloud"    # www-data inside the app containers

log "Installing NFS server + exporting to the app VMs"
apt-get install -y nfs-kernel-server
for ip in "${APP_IPS[@]}"; do
    line="${DATA_MOUNT}/nextcloud ${ip}(rw,sync,no_subtree_check,no_root_squash)"
    grep -qF "$line" /etc/exports || echo "$line" >> /etc/exports
done
exportfs -ra
systemctl enable --now nfs-kernel-server

# ── 4. Environment file with generated secrets ───────────────────────────
if [[ ! -f .env ]]; then
    log "Generating .env with random secrets"
    cp .env.example .env
    sed -i \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(rand 32)|" \
        -e "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$(rand 32)|" \
        -e "s|^FIREFLY_DB_PASSWORD=.*|FIREFLY_DB_PASSWORD=$(rand 32)|" \
        -e "s|^FIREFLY_APP_KEY=.*|FIREFLY_APP_KEY=$(rand 32)|" \
        -e "s|^AUTO_IMPORT_SECRET=.*|AUTO_IMPORT_SECRET=$(rand 32)|" \
        .env
    chown "$LOGIN_USER:$LOGIN_USER" .env
    chmod 600 .env
fi

# ── 5. Bank auto-import: dirs + daily cron ───────────────────────────────
log "Preparing importer dirs + daily bank auto-import (06:30)"
mkdir -p "${CONFIG_ROOT}/firefly-importer/keys" "${CONFIG_ROOT}/firefly-importer/import"
cat > /etc/cron.d/firefly-autoimport <<EOF
# Daily bank sync: runs every saved import config in the importer's /import
# dir (no-op until you save some — docs/10 "Connecting your banks")
30 6 * * * root cd $(pwd) && . ./.env && curl -sf "http://localhost:8081/autoimport?directory=/import&secret=\${AUTO_IMPORT_SECRET}" >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/firefly-autoimport

echo
log "Bootstrap done. Start the services (as ${LOGIN_USER}, after re-login):"
echo "  docker compose up -d"
echo
log "Copy these into BOTH app VMs' .env files (cloud/app/.env):"
grep -E '^(POSTGRES_PASSWORD|REDIS_PASSWORD)=' .env | sed 's/^/  /'
