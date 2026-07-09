#!/usr/bin/env bash
# One-time setup inside the cloud VM: install Docker, format/mount the data
# disk, generate .env with random secrets. Idempotent — safe to re-run.
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
else
    log "${DATA_DISK} already has a filesystem — keeping it"
fi

UUID="$(blkid -s UUID -o value "$DATA_DISK")"
if ! grep -q "$UUID" /etc/fstab; then
    log "Adding ${DATA_MOUNT} to /etc/fstab"
    mkdir -p "$DATA_MOUNT"
    echo "UUID=${UUID} ${DATA_MOUNT} xfs defaults,noatime 0 2" >> /etc/fstab
fi
mountpoint -q "$DATA_MOUNT" || { systemctl daemon-reload; mount "$DATA_MOUNT"; }

# ── 3. Directories ───────────────────────────────────────────────────────
log "Creating directories"
mkdir -p "$DATA_MOUNT/nextcloud" "$CONFIG_ROOT"
# Nextcloud runs as www-data (uid/gid 33) inside the container
chown 33:33 "$DATA_MOUNT/nextcloud"
chmod 750 "$DATA_MOUNT/nextcloud"

# ── 4. Environment file with generated secrets ───────────────────────────
if [[ ! -f .env ]]; then
    log "Generating .env with random secrets"
    cp .env.example .env
    NC_ADMIN_PW="$(rand 20)"
    sed -i \
        -e "s|^NEXTCLOUD_ADMIN_PASSWORD=.*|NEXTCLOUD_ADMIN_PASSWORD=${NC_ADMIN_PW}|" \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(rand 32)|" \
        -e "s|^FIREFLY_DB_PASSWORD=.*|FIREFLY_DB_PASSWORD=$(rand 32)|" \
        -e "s|^FIREFLY_APP_KEY=.*|FIREFLY_APP_KEY=$(rand 32)|" \
        .env
    chown "$LOGIN_USER:$LOGIN_USER" .env
    chmod 600 .env
    echo
    log "Nextcloud admin login:  admin / ${NC_ADMIN_PW}"
    echo "    (also stored in .env — keep it safe)"
else
    log ".env already exists — leaving it alone"
fi

echo
log "Bootstrap done. Next (as ${LOGIN_USER} — re-login first for docker group):"
echo "  docker compose up -d      # first run builds the Nextcloud+SMB image"
echo
echo "Then follow the first-run checklist in docs/10-cloud-stack.md"
