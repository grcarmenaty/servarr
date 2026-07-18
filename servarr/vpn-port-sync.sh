#!/bin/sh
# Keep qBittorrent's listen port in sync with the VPN's forwarded port
# (Proton VPN via gluetun). Runs in the qbt-port-sync sidecar, which shares
# gluetun's network namespace, so qBittorrent's WebUI is at 127.0.0.1:8080.
# docs/08.
#
# gluetun writes the current forwarded port to /gluetun/forwarded_port; it
# changes if the tunnel drops or gluetun restarts, so we poll and re-apply.
#
# Requires in qBittorrent: Options -> Web UI ->
#   "Bypass authentication for clients on localhost"  (ticked)
# so this API call needs no password.

set -eu
PORT_FILE="/gluetun/forwarded_port"
QBT="http://127.0.0.1:8080"
apk add --no-cache curl >/dev/null 2>&1 || true

last=""
echo "vpn-port-sync: watching ${PORT_FILE}"
while true; do
    if [ -s "$PORT_FILE" ]; then
        port="$(cat "$PORT_FILE" 2>/dev/null | tr -dc '0-9')"
        if [ -n "$port" ] && [ "$port" != "$last" ]; then
            if curl -fsS --data "json={\"listen_port\":${port}}" \
                 "${QBT}/api/v2/app/setPreferences" >/dev/null 2>&1; then
                echo "vpn-port-sync: set qBittorrent listen_port=${port}"
                last="$port"
            else
                echo "vpn-port-sync: qBittorrent not ready yet (will retry)"
            fi
        fi
    fi
    sleep 60
done
