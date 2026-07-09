#!/usr/bin/env bash
# Provision ntfy (self-hosted push notifications) inside the ntfy LXC.
# Pushed + run by 11-create-core-lxcs.sh; @TOKENS@ substituted before push.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> base packages + unattended security updates"
apt-get update
apt-get install -y curl ca-certificates gnupg apt-transport-https unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

if ! command -v ntfy >/dev/null 2>&1; then
    echo "==> installing ntfy (official repo)"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://archive.heckel.io/apt/pubkey.txt \
        | gpg --dearmor -o /etc/apt/keyrings/archive.heckel.io.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/archive.heckel.io.gpg] https://archive.heckel.io/apt debian main" \
        > /etc/apt/sources.list.d/archive.heckel.io.list
    apt-get update
    apt-get install -y ntfy
fi

echo "==> configuring"
cat > /etc/ntfy/server.yml <<EOF
base-url: "http://ntfy.@DOMAIN@"
listen-http: ":80"
cache-file: /var/cache/ntfy/cache.db
attachment-cache-dir: /var/cache/ntfy/attachments
behind-proxy: true
EOF
mkdir -p /var/cache/ntfy
chown -R ntfy:ntfy /var/cache/ntfy 2>/dev/null || true

systemctl enable --now ntfy
systemctl restart ntfy

echo "==> done. Server: http://@NTFY_IP@ / http://ntfy.@DOMAIN@"
echo "    Point Uptime Kuma notifications and the ntfy phone app at it"
echo "    (topics are open on the LAN — add auth if that ever bothers you:"
echo "     docs.ntfy.sh/config/#access-control)"
