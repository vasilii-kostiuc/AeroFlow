# Production deploy

One host, docker compose. Each service repository builds its image in GitHub
Actions and pushes it to GHCR (`ghcr.io/vasilii-kostiuc/aeroflow-{core,playback,tts,web}`);
the server only pulls. Caddy (the `aeroflow-web` image) is the only published
service: HTTPS for `DOMAIN`, the web SPA, and `/api` to core's PHP-FPM.

The agent is not part of this stack: it runs next to the speakers. Its
connection over the internet (amqps, token for `/internal`) is task 038.
Decisions behind this setup: `aeroflow-docs/tasks/037-prod-deploy.md`.

## Server, once

1. Docker installed, the deploy user in the `docker` group, ports 80 and 443
   open, `DOMAIN` resolving to the server.
2. `mkdir ~/aeroflow` and put `.env` there, filled in from `.env.example`.
3. Run the `deploy` workflow (or copy this directory and run `./deploy.sh`).
4. First administrator:
   `docker compose exec -u www-data core-app php bin/console app:users:create admin@example.org --role=admin`

## Deploy

`.github/workflows/deploy.yml` in the umbrella repository uploads this
directory to `~/aeroflow` (everything except `.env`; other files there are
deleted) and runs `deploy.sh`: pull images, generate JWT keys if missing,
migrate core and playback, restart.

Roll back one service: set `CORE_TAG=<commit sha>` (or another `*_TAG`) in
`.env` and deploy again.
