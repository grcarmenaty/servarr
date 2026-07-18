#!/usr/bin/env bash
# Create the AI service as a NATIVE LXC (Ollama + Open WebUI + voice) —
# the lighter alternative to the Docker VM (scripts/16). docs/16.
# Idempotent: re-running skips an existing container and re-applies config.
#
#   bash 17-create-ai-lxc.sh                 # CPU only, any node
#   bash 17-create-ai-lxc.sh --gpu 01:00     # bind-mount a GPU (run ON GPU_NODE)
#
# GPU note: unlike the VM's vfio passthrough, an LXC shares the host's GPU.
# The HOST NODE must have the NVIDIA driver installed first (NOT vfio — do
# NOT run 26-prepare-gpu-passthrough.sh for this path). This script installs
# the host driver for you if missing, then bind-mounts the device nodes.

source "$(dirname "$0")/lib.sh"
require_root
require_pve

GPU=""
if [[ "${1:-}" == "--gpu" ]]; then
    GPU="${2:-}"
    [[ "$GPU" =~ ^[0-9a-f]{2}:[0-9a-f]{2}$ ]] || die "usage: $0 [--gpu <pci-addr like 01:00>]"
    if [[ -n "${GPU_NODE:-}" && "$(hostname)" != "$GPU_NODE" ]]; then
        die "GPU bind-mount must run on ${GPU_NODE} (GPU_NODE in cluster.env) — this is $(hostname)"
    fi
    lspci -s "$GPU" >/dev/null 2>&1 || die "no device at ${GPU} on this node"
    DRV="$(lspci -nnks "$GPU" | sed -n 's/.*Kernel driver in use: //p' | head -1)"
    [[ "$DRV" == "vfio-pci" ]] && die "GPU is bound to vfio-pci (that's the VM path). For the LXC, the HOST keeps the driver — undo vfio: remove /etc/modprobe.d/vfio-gpu.conf + blacklist, update-initramfs -u, reboot."
fi

[[ -f /etc/pve/ceph.conf ]] || die "Ceph not set up yet — LXC rootfs lives on ${VM_POOL}"

# ── host NVIDIA driver (GPU path only) ───────────────────────────────────
if [[ -n "$GPU" ]] && ! command -v nvidia-smi >/dev/null 2>&1; then
    log "Installing the NVIDIA driver on the host ($(hostname)) for LXC GPU sharing"
    cat > /etc/apt/sources.list.d/nonfree-gpu.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    apt-get update
    apt-get install -y "pve-headers-$(uname -r)" nvidia-driver firmware-misc-nonfree || \
        apt-get install -y proxmox-headers nvidia-driver firmware-misc-nonfree
    warn "NVIDIA driver installed on the host — REBOOT $(hostname) once, then re-run this script."
    warn "(a host reboot loads the kernel module cleanly; nvidia-smi must work before the LXC starts)"
    exit 0
fi

# ── LXC template ─────────────────────────────────────────────────────────
log "Ensuring Debian 13 LXC template is available"
pveam update >/dev/null 2>&1 || true
TMPL="$(pveam available --section system | awk '/debian-13-standard/{print $2}' | sort -V | tail -1)"
[[ -n "$TMPL" ]] || die "no debian-13-standard template in 'pveam available'"
pveam list local | grep -q "$TMPL" || pveam download local "$TMPL"

KEYFILE=""
for k in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    [[ -f "$k" ]] && { KEYFILE="$k"; break; }
done
[[ -n "$KEYFILE" ]] || { ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519; KEYFILE=/root/.ssh/id_ed25519.pub; }

# ── create (idempotent) ──────────────────────────────────────────────────
if pct status "${AI_LXC_ID}" >/dev/null 2>&1; then
    log "CT ${AI_LXC_ID} already exists — skipping create, re-applying config"
else
    log "Creating AI LXC ${AI_LXC_ID}: ${AI_LXC_CORES} cores, $((AI_LXC_MEM/1024)) GB, ${AI_LXC_IP}${GPU:+, GPU ${GPU}}"
    # GPU sharing needs an unprivileged container with cgroup device access;
    # nesting=1 lets Ollama's runners work cleanly.
    pct create "${AI_LXC_ID}" "local:vztmpl/${TMPL}" \
        --hostname "${AI_NAME}" \
        --unprivileged 1 \
        --features nesting=1 \
        --ostype debian \
        --cores "${AI_LXC_CORES}" \
        --memory "${AI_LXC_MEM}" \
        --swap 0 \
        --rootfs "${VM_POOL}:${AI_LXC_ROOT_GB}" \
        --mp0 "${VM_POOL}:${AI_LXC_MODELS_GB},mp=/mnt/models,backup=0" \
        --net0 "name=eth0,bridge=vmbr0,ip=${AI_LXC_IP}/24,gw=${LAN_GATEWAY}" \
        --nameserver "${LAN_DNS}" \
        --ssh-public-keys "$KEYFILE" \
        --onboot 1
fi

# ── GPU device passthrough into the container config ─────────────────────
if [[ -n "$GPU" ]]; then
    command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not working on the host — reboot after the driver install, then re-run"
    CONF="/etc/pve/lxc/${AI_LXC_ID}.conf"
    if ! grep -q 'dev/nvidia0' "$CONF"; then
        log "Binding NVIDIA device nodes into CT ${AI_LXC_ID}"
        cat >> "$CONF" <<'EOF'
# NVIDIA GPU sharing (docs/16) — host driver, no vfio
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 234:* rwm
lxc.cgroup2.devices.allow: c 509:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
EOF
        pct stop "${AI_LXC_ID}" >/dev/null 2>&1 || true
    fi
fi

pct status "${AI_LXC_ID}" | grep -q running || pct start "${AI_LXC_ID}"

log "Waiting for container network"
pct exec "${AI_LXC_ID}" -- bash -c \
    'for i in $(seq 1 30); do getent hosts deb.debian.org >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1' \
    || die "no network inside CT ${AI_LXC_ID}"

log "Provisioning (native Ollama + Open WebUI + voice — a few minutes)"
tmp="$(mktemp -d)"
sed -e "s|@GPU@|${GPU:+yes}|g" "${SCRIPT_DIR}/core/provision-ai-lxc.sh" > "${tmp}/p.sh"
pct push "${AI_LXC_ID}" "${tmp}/p.sh" /root/provision.sh
rm -rf "$tmp"
pct exec "${AI_LXC_ID}" -- bash /root/provision.sh

# HA: only when NOT GPU-bound (a bind-mounted host device pins the CT)
if [[ -z "$GPU" ]] && [[ "${1:-}" == "--ha" || "${3:-}" == "--ha" ]]; then
    ha-manager add "ct:${AI_LXC_ID}" --state started 2>/dev/null || true
fi

echo
log "AI LXC ready → http://chat.home.lan (or http://${AI_LXC_IP}:3000)"
echo "  First visit = admin signup, then disable signups in Open WebUI settings."
echo "  Pull a model:  pct exec ${AI_LXC_ID} -- ollama pull qwen3:8b"
[[ -n "$GPU" ]] && echo "  Verify GPU:    pct exec ${AI_LXC_ID} -- nvidia-smi"
echo "  Docs: docs/16-ai-assistant.md (LXC section)"
