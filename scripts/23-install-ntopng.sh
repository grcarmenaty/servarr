#!/usr/bin/env bash
# Install ntopng (network traffic monitoring, GPL community edition) on a
# node, watching the VM bridge — i.e. every packet every guest on this node
# sends or receives. Run on EVERY node. Idempotent.
#
#   bash 23-install-ntopng.sh
#
# UI: http://<node>:3000 (first login admin/admin → forced password change)

source "$(dirname "$0")/lib.sh"
require_root
require_pve

log "Installing ntopng (Debian repos)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ntopng

# Debian's package reads /etc/ntopng.conf (one option per line);
# newer ntop.org packaging uses /etc/ntopng/ntopng.conf — handle both.
CONF=/etc/ntopng.conf
[[ -d /etc/ntopng ]] && CONF=/etc/ntopng/ntopng.conf

log "Configuring ${CONF}: capture on vmbr0, UI on :3000"
cat > "$CONF" <<'EOF'
# Watch the guest bridge: all VM/LXC traffic on this node passes here
-i=vmbr0
# Web UI
-w=3000
EOF

systemctl enable --now ntopng
systemctl restart ntopng
sleep 2
systemctl --no-pager --lines=3 status ntopng || true

echo
log "ntopng running: http://$(hostname -I | awk '{print $1}'):3000"
log "First login: admin/admin (it forces a change). Repeat on each node —"
log "each instance sees the guests running on ITS node (docs/13)."
