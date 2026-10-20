#!/bin/sh
# Runs once, on the first start of an empty Postgres volume: playback gets its
# own database and user next to core's (POSTGRES_DB / POSTGRES_USER).
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
CREATE USER playback WITH PASSWORD '${PLAYBACK_DB_PASSWORD}';
CREATE DATABASE aeroflow_playback OWNER playback;
EOSQL
