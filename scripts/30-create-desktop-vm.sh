#!/usr/bin/env bash
# Desktop VM factory (docs/15): stamp out a Debian 13 + XFCE + xrdp desktop
# VM in one command. Run on any cluster node.
#
#   bash 30-create-desktop-vm.sh <name> [memory_mb] [cores] [disk_gb]
#   bash 30-create-desktop-vm.sh testbox
#   bash 30-create-desktop-vm.sh workbench 8192 4 60
#
# The VM gets a DHCP address, installs the desktop on first boot
# (~10 minutes — watch the console), and is then reachable via any RDP
# client or through Guacamole (http://desktop.home.lan). Delete it later
# with: qm stop <vmid>; qm destroy <vmid> --purge

source "$(dirname "$0")/lib.sh"
require_root
require_pve

NAME="${1:-}"
MEM="${2:-4096}"
CORES="${3:-2}"
DISK_GB="${4:-40}"
[[ -n "$NAME" ]] || die "usage: $0 <name> [memory_mb] [cores] [disk_gb]"
[[ "$NAME" =~ ^[a-z0-9-]+$ ]] || die "name must be lowercase alphanumeric/hyphens"

IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/$(basename "$IMG_URL")"
DESKTOP_USER="desk"
PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 12)"

KEYFILE=""
for k in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    [[ -f "$k" ]] && { KEYFILE="$k"; break; }
done
[[ -n "$KEYFILE" ]] || { ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519; KEYFILE=/root/.ssh/id_ed25519.pub; }

if [[ ! -f "$IMG" ]]; then
    log "Downloading Debian 13 cloud image"
    wget -q --show-progress -O "${IMG}.part" "$IMG_URL"
    mv "${IMG}.part" "$IMG"
fi

# snippets storage for the cloud-init user-data
CONTENT="$(pvesh get /storage/local --output-format json | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')"
if [[ "$CONTENT" != *snippets* ]]; then
    log "Enabling snippets on storage 'local'"
    pvesm set local --content "${CONTENT},snippets"
fi

VMID="$(pvesh get /cluster/nextid)"
SNIPPET="/var/lib/vz/snippets/desktop-${VMID}.yaml"

log "Writing cloud-init user-data (${SNIPPET})"
mkdir -p /var/lib/vz/snippets
cat > "$SNIPPET" <<EOF
#cloud-config
hostname: ${NAME}
manage_etc_hosts: true
users:
  - name: ${DESKTOP_USER}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - $(cat "$KEYFILE")
chpasswd:
  expire: false
  list: |
    ${DESKTOP_USER}:${PASSWORD}
package_update: true
packages:
  - task-xfce-desktop
  - xrdp
  - dbus-x11
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
  - adduser xrdp ssl-cert
  - bash -c 'echo xfce4-session > /home/${DESKTOP_USER}/.xsession && chown ${DESKTOP_USER}:${DESKTOP_USER} /home/${DESKTOP_USER}/.xsession'
  - systemctl enable --now xrdp
EOF

log "Creating desktop VM ${VMID} (${NAME}): ${CORES} cores, $((MEM / 1024)) GB RAM, ${DISK_GB}G disk"
qm create "$VMID" \
    --name "$NAME" \
    --memory "$MEM" \
    --cores "$CORES" \
    --cpu host \
    --net0 "virtio,bridge=vmbr0" \
    --scsihw virtio-scsi-single \
    --agent enabled=1 \
    --ostype l26 \
    --tags desktop

qm set "$VMID" --scsi0 "${VM_POOL}:0,import-from=${IMG},discard=on,iothread=1"
qm disk resize "$VMID" scsi0 "${DISK_GB}G"
qm set "$VMID" \
    --ide2 "${VM_POOL}:cloudinit" \
    --boot order=scsi0 \
    --ipconfig0 "ip=dhcp" \
    --nameserver "${LAN_DNS}" \
    --cicustom "user=local:snippets/desktop-${VMID}.yaml"

qm start "$VMID"

echo
log "Desktop '${NAME}' (VMID ${VMID}) is installing XFCE — first boot takes ~10 min."
echo "  Login:      ${DESKTOP_USER} / ${PASSWORD}"
echo "  Watch:      web UI → VM ${VMID} → Console (noVNC)"
echo "  Find its IP once booted:"
echo "      qm guest cmd ${VMID} network-get-interfaces | grep -o '\"ip-address\": \"10[^\"]*\"'"
echo "  Connect:    any RDP client → <ip>:3389, or add it in Guacamole"
echo "              (http://desktop.home.lan) — docs/15-remote-desktops.md"
echo "  Destroy:    qm stop ${VMID} && qm destroy ${VMID} --purge && rm ${SNIPPET}"
