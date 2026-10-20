#!/usr/bin/env bash
# Brings the stack up to the images currently in GHCR: pull, migrate, restart.
# Run on the server from any directory; the deploy workflow does exactly this.
# Safe to repeat.
set -euo pipefail
cd "$(dirname "$0")"

# Without .env every secret is blank, and Postgres and RabbitMQ would keep the
# blank credentials from their first start: stop before creating anything.
[ -f .env ] || { echo "$(pwd)/.env not found: create it from .env.example" >&2; exit 1; }

docker compose pull --quiet
docker compose up -d --wait postgres rabbitmq

# Core's JWT signing keys live in a volume, never in an image: generated once.
docker compose run --rm --no-deps --user www-data core-app \
    php bin/console lexik:jwt:generate-keypair --skip-if-exists

docker compose run --rm --no-deps --user www-data core-app \
    php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration
docker compose run --rm --no-deps playback-worker \
    php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration

docker compose up -d --remove-orphans
docker image prune -f
