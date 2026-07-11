#!/usr/bin/env bash
# Provision Forgejo (self-hosted git + CI) inside the forgejo LXC.
# Pushed + run by 11-create-core-lxcs.sh; @TOKENS@ substituted before push.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> base packages + unattended security updates"
apt-get update
apt-get install -y git git-lfs curl ca-certificates unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

if ! command -v forgejo >/dev/null 2>&1; then
    echo "==> downloading the latest Forgejo release"
    TAG="$(curl -fsSL https://codeberg.org/api/v1/repos/forgejo/forgejo/releases/latest \
        | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p')"
    [[ -n "$TAG" ]] || { echo "ERROR: could not determine latest release"; exit 1; }
    echo "    ${TAG}"
    curl -fL -o /usr/local/bin/forgejo \
        "https://codeberg.org/forgejo/forgejo/releases/download/${TAG}/forgejo-${TAG#v}-linux-amd64"
    chmod +x /usr/local/bin/forgejo
fi
forgejo --version

id -u git >/dev/null 2>&1 || adduser --system --group --disabled-password \
    --shell /bin/bash --home /home/git git
mkdir -p /var/lib/forgejo /etc/forgejo
chown -R git:git /var/lib/forgejo

if [[ ! -f /etc/forgejo/app.ini ]]; then
    echo "==> writing app.ini (sqlite, registration disabled)"
    cat > /etc/forgejo/app.ini <<EOF
APP_NAME = home git
RUN_USER = git
WORK_PATH = /var/lib/forgejo

[server]
DOMAIN = git.@DOMAIN@
ROOT_URL = http://git.@DOMAIN@/
HTTP_PORT = 3000

[database]
DB_TYPE = sqlite3
PATH = /var/lib/forgejo/data/forgejo.db

[service]
DISABLE_REGISTRATION = true

[security]
INSTALL_LOCK = true
SECRET_KEY = $(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)
INTERNAL_TOKEN = $(/usr/local/bin/forgejo generate secret INTERNAL_TOKEN)
EOF
    chown root:git /etc/forgejo/app.ini
    chmod 640 /etc/forgejo/app.ini
fi

cat > /etc/systemd/system/forgejo.service <<'EOF'
[Unit]
Description=Forgejo
After=network.target

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/forgejo
ExecStart=/usr/local/bin/forgejo web --config /etc/forgejo/app.ini
Restart=always
Environment=USER=git HOME=/home/git

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now forgejo

echo "==> done. Create your admin account (registration is disabled):"
echo "    su -s /bin/bash git -c 'forgejo --config /etc/forgejo/app.ini \\"
echo "      admin user create --admin --username YOU --random-password --email you@@DOMAIN@'"
echo "    then log in at http://git.@DOMAIN@ and change the printed password."
echo "    (clone over http; push THIS repo here for the full circle)"
