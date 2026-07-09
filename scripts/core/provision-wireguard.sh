#!/usr/bin/env bash
# Provision WireGuard (remote-access VPN) inside the wireguard LXC.
# Pushed + run by 11-create-core-lxcs.sh; expects /root/wg-add-peer pushed
# alongside. @TOKENS@ are substituted before push.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

WG_NET="@WG_SUBNET@"                      # e.g. 10.8.0.0/24
WG_SERVER_IP="${WG_NET%.*/*}.1"           # first host, e.g. 10.8.0.1

echo "==> base packages + unattended security updates"
apt-get update
apt-get install -y wireguard iptables qrencode unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

if [[ -f /etc/wireguard/wg0.conf ]]; then
    echo "==> wg0 already configured"
else
    echo "==> generating server config"
    umask 077
    wg genkey > /etc/wireguard/server.key
    wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub

    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server.key)
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET} -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET} -o eth0 -j MASQUERADE
EOF

    # settings wg-add-peer needs later
    cat > /etc/wireguard/params <<EOF
WG_NET=${WG_NET}
WG_ENDPOINT=@WG_ENDPOINT@
CLIENT_DNS=@ADGUARD_IP@
LAN_NET=$(ip -o -4 addr show eth0 | awk '{print $4}' | head -1 | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".0/24"}')
EOF
fi

echo "==> enabling forwarding + service"
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf
install -m 0755 /root/wg-add-peer /usr/local/bin/wg-add-peer
systemctl enable --now wg-quick@wg0

echo "==> done. Add clients with:  wg-add-peer <device-name>"
if ! grep -q '^WG_ENDPOINT=..*' /etc/wireguard/params; then
    echo "WARNING: WG_ENDPOINT is empty in cluster.env — client configs will need"
    echo "         the Endpoint line filled in by hand (your DDNS hostname:51820)."
fi
echo "    Remember: forward UDP 51820 on the router → @WIREGUARD_IP@ (docs/09)"
