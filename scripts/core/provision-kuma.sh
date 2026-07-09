#!/usr/bin/env bash
# Provision Uptime Kuma (monitoring + alerting) inside the kuma LXC.
# Native install (no Docker): Node.js from Debian 13 repos + systemd unit.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

KUMA_DIR=/opt/uptime-kuma

echo "==> base packages + unattended security updates"
apt-get update
apt-get install -y git nodejs npm unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

node -e 'process.exit(parseInt(process.versions.node) >= 18 ? 0 : 1)' \
    || { echo "ERROR: Node >= 18 required"; exit 1; }

if [[ -d "$KUMA_DIR" ]]; then
    echo "==> Uptime Kuma already installed"
else
    echo "==> installing Uptime Kuma (npm setup takes a few minutes)"
    git clone --depth 1 https://github.com/louislam/uptime-kuma.git "$KUMA_DIR"
    cd "$KUMA_DIR"
    npm run setup
fi

id -u kuma >/dev/null 2>&1 || useradd -r -d "$KUMA_DIR" -s /usr/sbin/nologin kuma
chown -R kuma:kuma "$KUMA_DIR"

cat > /etc/systemd/system/uptime-kuma.service <<EOF
[Unit]
Description=Uptime Kuma
After=network.target

[Service]
Type=simple
User=kuma
WorkingDirectory=${KUMA_DIR}
ExecStart=/usr/bin/node server/server.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now uptime-kuma

echo "==> done. First run: http://@KUMA_IP@:3001 — create the admin account,"
echo "    then add monitors per docs/09-core-services.md"
