#!/usr/bin/env bash
# Export the media library over SMB from the servarr VM — for Nextcloud's
# external storage (docs/10) and for laptops/TVs on the LAN.
# Run once inside the servarr VM, after bootstrap.sh:
#
#   sudo bash setup-samba.sh
#
# Creates a read-write [media] share on /mnt/data/media for the "media" user
# (you'll be prompted to set the SMB password).

set -euo pipefail
log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

MEDIA_USER="${SUDO_USER:-media}"
MEDIA_PATH=/mnt/data/media
[[ -d "$MEDIA_PATH" ]] || die "${MEDIA_PATH} missing — run bootstrap.sh first"

log "Installing Samba"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y samba

if ! grep -q '^\[media\]' /etc/samba/smb.conf; then
    log "Adding [media] share to smb.conf"
    cat >> /etc/samba/smb.conf <<EOF

[media]
   path = ${MEDIA_PATH}
   valid users = ${MEDIA_USER}
   read only = no
   browseable = yes
   # keep new files owned by the media user so *arr hardlinks keep working
   force user = ${MEDIA_USER}
   force group = ${MEDIA_USER}
   create mask = 0664
   directory mask = 0775
EOF
else
    log "[media] share already present"
fi

log "Set the SMB password for user '${MEDIA_USER}' (used by Nextcloud and LAN devices):"
smbpasswd -a "$MEDIA_USER"

systemctl enable --now smbd
systemctl restart smbd

log "Done. Share: \\\\$(hostname -I | awk '{print $1}')\\media  (user: ${MEDIA_USER})"
echo "Wire it into Nextcloud per docs/10-cloud-stack.md"
