#!/usr/bin/env bash
# Setup inside the AI VM (docs/16). CPU-only by default (single pass).
# If a GPU is passed through to this VM, it becomes two-pass:
#
#   sudo bash bootstrap.sh     # GPU present: installs driver → asks reboot
#   sudo bash bootstrap.sh     # (GPU only) second pass after the reboot
#
# Idempotent either way.

set -euo pipefail
cd "$(dirname "$0")"

log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

DATA_DISK="${1:-/dev/sdb}"
DATA_MOUNT="/mnt/models"
LOGIN_USER="${SUDO_USER:-cloud}"
export DEBIAN_FRONTEND=noninteractive

HAS_GPU=false
if lspci 2>/dev/null | grep -qi nvidia; then HAS_GPU=true; fi

# ── GPU pass (only when a card is passed through) ────────────────────────
if $HAS_GPU && { ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; }; then
    log "GPU detected: installing the NVIDIA driver (Debian non-free)"
    sed -i 's/^Components: main.*/Components: main contrib non-free non-free-firmware/' \
        /etc/apt/sources.list.d/debian.sources
    apt-get update
    apt-get install -y linux-headers-amd64 nvidia-driver firmware-misc-nonfree
    echo
    log "Driver installed. REBOOT NOW (sudo reboot), then run bootstrap.sh again."
    exit 0
fi
$HAS_GPU && log "GPU ready: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)" \
         || log "No GPU — CPU inference setup (the default; docs/16)"

# ── Model disk ───────────────────────────────────────────────────────────
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
    mkdir -p "$DATA_MOUNT"
    echo "UUID=${UUID} ${DATA_MOUNT} xfs defaults,noatime 0 2" >> /etc/fstab
}
mountpoint -q "$DATA_MOUNT" || { systemctl daemon-reload; mount "$DATA_MOUNT"; }
mkdir -p "$DATA_MOUNT"/{ollama,whisper,piper} /opt/ai/config

# ── Docker ───────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker"
    apt-get update
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

# ── NVIDIA container toolkit (GPU only) ──────────────────────────────────
if $HAS_GPU && ! command -v nvidia-ctk >/dev/null 2>&1; then
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
if $HAS_GPU; then
    echo "  docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d"
else
    echo "  docker compose up -d"
fi
echo "  docker exec ollama ollama pull qwen3:8b      # first model (docs/16 size table)"
echo
echo "First browser visit to http://chat.home.lan → CREATE YOUR ACCOUNT"
echo "(first account = admin), then ENABLE_SIGNUP=false in .env + up -d again."
