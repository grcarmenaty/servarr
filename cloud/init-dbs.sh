#!/bin/bash
# Runs once on first postgres start (docker-entrypoint-initdb.d): create the
# Firefly III database alongside the Nextcloud one.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
    CREATE USER firefly WITH PASSWORD '${FIREFLY_DB_PASSWORD}';
    CREATE DATABASE firefly OWNER firefly;
EOSQL
