#!/usr/bin/env bash
# Provision AdGuard Home inside the adguard LXC. Pushed + run by
# 11-create-core-lxcs.sh; @TOKENS@ are substituted before push.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> base packages + unattended security updates"
apt-get update
apt-get install -y curl ca-certificates unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

if [[ -d /opt/AdGuardHome ]]; then
    echo "==> AdGuard Home already installed"
else
    echo "==> installing AdGuard Home"
    curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
        | sh -s -- -v
fi

echo "==> done. Finish setup in the browser: http://@ADGUARD_IP@:3000"
echo "    (wizard: web UI on port 80, DNS on 53, set an admin password)"
echo "    Then add DNS rewrites per docs/09-core-services.md"
