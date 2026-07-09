#!/usr/bin/env bash
# Load Guacamole's database schema — run ONCE on cloud-data, after
# `docker compose up -d` has the db + guacamole containers running:
#
#   sudo bash init-guacamole.sh
#
# Idempotent: skips if the schema already exists.

set -euo pipefail
cd "$(dirname "$0")"
log() { echo -e "\e[1;32m==>\e[0m $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; exit 1; }

[[ -f .env ]] || die "no .env — run bootstrap.sh first"
source .env

docker ps --format '{{.Names}}' | grep -q '^cloud-db$' || die "cloud-db container not running — docker compose up -d first"

if docker exec -e PGPASSWORD="${GUACAMOLE_DB_PASSWORD}" cloud-db \
        psql -U guacamole -d guacamole -tAc "SELECT to_regclass('guacamole_entity')" | grep -q guacamole_entity; then
    log "Guacamole schema already loaded"
    exit 0
fi

log "Generating + loading Guacamole schema"
docker run --rm guacamole/guacamole:latest /opt/guacamole/bin/initdb.sh --postgresql \
    | docker exec -i -e PGPASSWORD="${GUACAMOLE_DB_PASSWORD}" cloud-db \
        psql -U guacamole -d guacamole

docker restart guacamole >/dev/null
log "Done. Login: http://desktop.home.lan — user 'guacadmin' / 'guacadmin'."
log "CHANGE THAT PASSWORD FIRST THING (Settings → Users), then add"
log "connections to your desktop VMs (docs/15-remote-desktops.md)."
