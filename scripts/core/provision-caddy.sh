#!/usr/bin/env bash
# Provision Caddy (reverse proxy + landing portal) inside the caddy LXC.
# Pushed + run by 11-create-core-lxcs.sh; expects /root/Caddyfile and
# /root/index.html pushed alongside.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> base packages + unattended security updates"
apt-get update
apt-get install -y curl ca-certificates gnupg unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

if ! command -v caddy >/dev/null 2>&1; then
    echo "==> installing Caddy (official repo)"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
fi

echo "==> installing Caddyfile + portal page"
mkdir -p /var/www/home
mv /root/index.html /var/www/home/index.html
mv /root/Caddyfile /etc/caddy/Caddyfile
chown -R caddy:caddy /var/www/home 2>/dev/null || true

caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl reload caddy

echo "==> done. Portal: http://@CADDY_IP@  (nice names work once AdGuard rewrites are set)"
