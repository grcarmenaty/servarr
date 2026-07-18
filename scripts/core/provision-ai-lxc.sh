#!/usr/bin/env bash
# Provision native Ollama + Open WebUI + Wyoming voice inside the AI LXC.
# Pushed + run by 17-create-ai-lxc.sh. Idempotent. @GPU@ = "yes" if a GPU
# was bind-mounted.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
GPU="@GPU@"

log() { echo -e "\e[1;32m==>\e[0m $*"; }

log "base packages + unattended security updates"
apt-get update
apt-get install -y curl ca-certificates python3 python3-venv python3-pip \
    ffmpeg unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

mkdir -p /mnt/models/ollama /mnt/models/whisper /mnt/models/piper

# ── optional GPU userspace (must match the host driver; Ollama falls back
#    to CPU if CUDA can't initialise, so this never blocks the install) ───
if [[ "$GPU" == "yes" ]]; then
    log "installing NVIDIA userspace libraries (GPU path)"
    . /etc/os-release
    cat > /etc/apt/sources.list.d/nonfree.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${VERSION_CODENAME}
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    apt-get update
    # userspace only — the kernel module lives on the host (bind-mounted /dev)
    apt-get install -y libnvidia-ml1 nvidia-smi || \
        echo "  (userspace libs imperfect — Ollama will run CPU-only until the"
        echo "   in-container libs match the host driver version; see docs/16)"
fi

# ── Ollama (official installer → systemd service) ────────────────────────
if ! command -v ollama >/dev/null 2>&1; then
    log "installing Ollama"
    curl -fsSL https://ollama.com/install.sh | sh
fi
# store models on the mounted disk; keep the API on loopback (no native auth)
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_MODELS=/mnt/models/ollama"
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_KEEP_ALIVE=30m"
EOF
systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama

# ── Open WebUI (python venv → systemd) ───────────────────────────────────
if [[ ! -x /opt/open-webui/venv/bin/open-webui ]]; then
    log "installing Open WebUI (pip; this pulls a lot — be patient)"
    python3 -m venv /opt/open-webui/venv
    /opt/open-webui/venv/bin/pip install --upgrade pip
    /opt/open-webui/venv/bin/pip install open-webui
fi
id -u openwebui >/dev/null 2>&1 || useradd -r -d /opt/open-webui -s /usr/sbin/nologin openwebui
mkdir -p /opt/open-webui/data
chown -R openwebui:openwebui /opt/open-webui
cat > /etc/systemd/system/open-webui.service <<'EOF'
[Unit]
Description=Open WebUI
After=network.target ollama.service
Wants=ollama.service

[Service]
User=openwebui
Environment="DATA_DIR=/opt/open-webui/data"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:11434"
Environment="WEBUI_URL=http://chat.home.lan"
Environment="HOST=0.0.0.0"
Environment="PORT=3000"
ExecStart=/opt/open-webui/venv/bin/open-webui serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now open-webui

# ── Wyoming voice services for Home Assistant (venvs → systemd) ───────────
install_wyoming() { # name pip-pkg exec-args...
    local name="$1" pkg="$2"; shift 2
    if [[ ! -x "/opt/${name}/venv/bin/${name}" ]]; then
        log "installing ${name}"
        python3 -m venv "/opt/${name}/venv"
        "/opt/${name}/venv/bin/pip" install --upgrade pip >/dev/null
        "/opt/${name}/venv/bin/pip" install "$pkg"
    fi
    cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${name}
After=network.target

[Service]
ExecStart=/opt/${name}/venv/bin/${name} $*
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}
install_wyoming wyoming-faster-whisper wyoming-faster-whisper \
    --uri tcp://0.0.0.0:10300 --model small-int8 --language es --data-dir /mnt/models/whisper
install_wyoming wyoming-piper wyoming-piper \
    --uri tcp://0.0.0.0:10301 --voice es_ES-davefx-medium --data-dir /mnt/models/piper --download-dir /mnt/models/piper
systemctl daemon-reload
systemctl enable --now wyoming-faster-whisper wyoming-piper

echo
log "done. Open WebUI on :3000, Ollama on 127.0.0.1:11434, Whisper :10300, Piper :10301"
[[ "$GPU" == "yes" ]] && { command -v nvidia-smi >/dev/null && nvidia-smi -L || echo "  (GPU libs not ready — running CPU-only; docs/16)"; }
echo "First browser visit → create the admin account, then disable signups."
