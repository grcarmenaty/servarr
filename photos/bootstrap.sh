#!/usr/bin/env bash
# One-time setup inside the photos VM: Docker, photo-library disk, and
# Immich via its OFFICIAL release compose (fetched, not vendored — Immich
# moves fast and pins its own postgres/ML images). Idempotent.
#
#   sudo bash bootstrap.sh [data-disk]     # default data disk: /dev/sdb

set -euo pipefail
cd "$(dirname "$0")"

log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

DATA_DISK="${1:-/dev/sdb}"
DATA_MOUNT="/mnt/photos"
LOGIN_USER="${SUDO_USER:-cloud}"

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# ── 1. Docker (official repo) ────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
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

# ── 2. Photo library disk ────────────────────────────────────────────────
[[ -b "$DATA_DISK" ]] || die "data disk ${DATA_DISK} not found (lsblk; pass as \$1)"
ROOT_DISK="/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -n1)"
[[ "$DATA_DISK" != "$ROOT_DISK" ]] || die "${DATA_DISK} is the OS disk"

if ! blkid "$DATA_DISK" >/dev/null 2>&1; then
    log "Formatting ${DATA_DISK} as XFS"
    apt-get install -y xfsprogs
    mkfs.xfs "$DATA_DISK"
fi
UUID="$(blkid -s UUID -o value "$DATA_DISK")"
grep -q "$UUID" /etc/fstab || {
    mkdir -p "$DATA_MOUNT"
    echo "UUID=${UUID} ${DATA_MOUNT} xfs defaults,noatime 0 2" >> /etc/fstab
}
mountpoint -q "$DATA_MOUNT" || { systemctl daemon-reload; mount "$DATA_MOUNT"; }
mkdir -p "$DATA_MOUNT/library"

# ── 3. Immich — official compose from the latest release ─────────────────
if [[ ! -f docker-compose.yml ]]; then
    log "Fetching Immich's official docker-compose.yml + example .env"
    curl -fsSL -o docker-compose.yml \
        https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
    curl -fsSL -o .env \
        https://github.com/immich-app/immich/releases/latest/download/example.env

    sed -i \
        -e "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${DATA_MOUNT}/library|" \
        -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$(rand 32)|" \
        .env
    grep -q '^TZ=' .env || echo "TZ=$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)" >> .env
    chown "$LOGIN_USER:$LOGIN_USER" docker-compose.yml .env
    chmod 600 .env
else
    log "docker-compose.yml already present — leaving it alone"
fi

echo
log "Bootstrap done. Next (as ${LOGIN_USER}, after re-login):"
echo "  docker compose up -d"
echo
echo "First run: http://$(hostname -I | awk '{print $1}'):2283 → create the"
echo "admin account. Walkthrough: docs/11-photos.md"
