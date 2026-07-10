#!/usr/bin/env bash
# Two-pass setup inside the AI VM (docs/16). Idempotent — run, reboot when
# told, run again:
#
#   pass 1:  sudo bash bootstrap.sh    # NVIDIA driver → asks for a reboot
#   pass 2:  sudo bash bootstrap.sh    # data disk, docker, GPU runtime, stack

set -euo pipefail
cd "$(dirname "$0")"

log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

DATA_DISK="${1:-/dev/sdb}"
DATA_MOUNT="/mnt/models"
LOGIN_USER="${SUDO_USER:-cloud}"
export DEBIAN_FRONTEND=noninteractive

# ── Pass 1: NVIDIA driver ────────────────────────────────────────────────
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
    log "Pass 1: installing the NVIDIA driver (Debian non-free)"
    # enable contrib + non-free components on the cloud image's deb822 sources
    sed -i 's/^Components: main.*/Components: main contrib non-free non-free-firmware/' \
        /etc/apt/sources.list.d/debian.sources
    apt-get update
    apt-get install -y linux-headers-amd64 nvidia-driver firmware-misc-nonfree
    echo
    log "Driver installed. REBOOT NOW (sudo reboot), then run bootstrap.sh again."
    exit 0
fi

log "Pass 2: driver OK →"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

# ── Model disk ───────────────────────────────────────────────────────────
[[ -b "$DATA_DISK" ]] || die "data disk ${DATA_DISK} not found"
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
mkdir -p "$DATA_MOUNT/ollama" /opt/ai/config

# ── Docker + NVIDIA container runtime ────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker"
    apt-get install -y ca-certificates curl gnupg
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

if ! command -v nvidia-ctk >/dev/null 2>&1; then
    log "Installing nvidia-container-toolkit"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi

# ── Environment ──────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    cp .env.example .env
    chown "$LOGIN_USER:$LOGIN_USER" .env
fi

echo
log "Bootstrap done. Next (as ${LOGIN_USER}, after re-login for docker group):"
echo "  docker compose up -d"
echo "  docker exec ollama ollama pull qwen3:14b      # first model (docs/16 has a size table)"
echo
echo "First browser visit to http://chat.home.lan → CREATE YOUR ACCOUNT"
echo "(first account = admin), then set ENABLE_SIGNUP=false in .env and"
echo "'docker compose up -d' again. Details: docs/16-ai-assistant.md"
