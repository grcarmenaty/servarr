#!/usr/bin/env bash
# One-time setup inside a Nextcloud app VM (cloud1 or cloud2): Docker, NFS
# mount of the shared html/data from cloud-data, .env. Idempotent.
#
#   sudo bash bootstrap.sh
#
# Run on cloud-data FIRST (its bootstrap prints the DB/Redis passwords this
# .env needs).

set -euo pipefail
cd "$(dirname "$0")"

log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

CLOUDDATA_IP="10.0.0.22"
NFS_MOUNT="/mnt/nextcloud"
LOGIN_USER="${SUDO_USER:-cloud}"

# ── 1. Docker (official repo) ────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker from download.docker.com"
    apt-get update
    apt-get install -y ca-certificates curl
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

# ── 2. NFS mount of the shared Nextcloud state ───────────────────────────
log "Mounting ${CLOUDDATA_IP}:/mnt/clouddata/nextcloud at ${NFS_MOUNT}"
apt-get install -y nfs-common
mkdir -p "$NFS_MOUNT"
FSTAB="${CLOUDDATA_IP}:/mnt/clouddata/nextcloud ${NFS_MOUNT} nfs4 _netdev,x-systemd.automount,noatime 0 0"
grep -qF "$FSTAB" /etc/fstab || echo "$FSTAB" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$NFS_MOUNT" || mount "$NFS_MOUNT" \
    || die "cannot mount NFS — is cloud-data bootstrapped and running?"
[[ -d "$NFS_MOUNT/html" && -d "$NFS_MOUNT/data" ]] \
    || die "shared html/data dirs missing on cloud-data"

# ── 3. Environment file ──────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    cp .env.example .env
    if [[ "$(hostname)" == "cloud1" ]]; then
        sed -i 's|^#COMPOSE_PROFILES=cron|COMPOSE_PROFILES=cron|' .env
        log "this is cloud1 → cron profile enabled"
    fi
    # first-install admin password (only used if this VM performs the install)
    ADMIN_PW="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
    sed -i "s|^NEXTCLOUD_ADMIN_PASSWORD=.*|NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PW}|" .env
    chown "$LOGIN_USER:$LOGIN_USER" .env
    chmod 600 .env
    log "created .env — NOW EDIT IT: paste POSTGRES_PASSWORD and REDIS_PASSWORD"
    log "from cloud-data's .env. Admin password (first install only): ${ADMIN_PW}"
else
    log ".env already exists — leaving it alone"
fi

echo
log "Next (as ${LOGIN_USER}, after re-login):"
echo "  docker compose up -d --build"
echo
echo "Bring cloud1 up FIRST and let it finish installing (http://<ip>:8080)"
echo "before starting cloud2 — full order in docs/10-cloud-stack.md"
