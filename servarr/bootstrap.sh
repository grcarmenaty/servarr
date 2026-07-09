#!/usr/bin/env bash
# One-time setup inside the servarr VM: install Docker, format/mount the
# media data disk, create the directory tree, prepare the .env.
# Idempotent — safe to re-run.
#
#   sudo bash bootstrap.sh [data-disk]     # default data disk: /dev/sdb

set -euo pipefail
cd "$(dirname "$0")"

log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

DATA_DISK="${1:-/dev/sdb}"
DATA_MOUNT="/mnt/data"
CONFIG_ROOT="/opt/servarr/config"
MEDIA_USER="${SUDO_USER:-media}"

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
usermod -aG docker "$MEDIA_USER" 2>/dev/null || true

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
log "data disk mounted at ${DATA_MOUNT} ($(df -h --output=size "$DATA_MOUNT" | tail -1 | tr -d ' '))"

# ── 3. Directory tree (TRaSH-guides layout) ──────────────────────────────
log "Creating directory tree"
mkdir -p "$DATA_MOUNT"/media/{movies,tv,music,audiobooks,podcasts,books} \
         "$DATA_MOUNT"/torrents/{movies,tv,music,audiobooks,books} \
         "$CONFIG_ROOT"
chown -R "$MEDIA_USER:$MEDIA_USER" "$DATA_MOUNT" "$CONFIG_ROOT"

# ── 4. Environment file ──────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    cp .env.example .env
    sed -i "s|^PUID=.*|PUID=$(id -u "$MEDIA_USER")|; s|^PGID=.*|PGID=$(id -g "$MEDIA_USER")|" .env
    chown "$MEDIA_USER:$MEDIA_USER" .env
    log "created .env — review it (timezone, VPN settings)"
else
    log ".env already exists — leaving it alone"
fi

echo
log "Bootstrap done. Next (as ${MEDIA_USER} — re-login first for docker group):"
echo "  docker compose up -d                                        # no VPN"
echo "  docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d   # with VPN"
echo
echo "Then follow the first-run checklist in docs/08-servarr-stack.md"
