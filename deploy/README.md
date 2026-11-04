# Production deploy

One host, docker compose. Each service repository builds its image in GitHub
Actions and pushes it to GHCR (`ghcr.io/vasilii-kostiuc/aeroflow-{core,playback,tts,web}`);
the server only pulls. Caddy (the `aeroflow-web` image) serves HTTPS for
`DOMAIN`: the web SPA, and `/api` and `/internal` to core's PHP-FPM. The only
other published port is RabbitMQ's TLS port 5671, for the agent.

The agent is not part of this stack: it runs next to the speakers and connects
to the server itself (see "Agent" below). Decisions behind this setup:
`aeroflow-docs/tasks/037-prod-deploy.md` and `038-agent-over-internet.md`.

## Server, once

1. Docker installed, the deploy user in the `docker` group, ports 80, 443 and
   5671 open (the Hetzner Cloud Firewall too), `DOMAIN` resolving to the server.
2. `mkdir ~/aeroflow` and put `.env` there, filled in from `.env.example`.
3. Run the `deploy` workflow (or copy this directory and run `./deploy.sh`).
4. First administrator:
   `docker compose exec -u www-data core-app php bin/console app:users:create admin@example.org --role=admin`

## Deploy

`.github/workflows/deploy.yml` in the umbrella repository uploads this
directory to `~/aeroflow` (everything except `.env`; other files there are
deleted) and runs `deploy.sh`: pull images, issue the broker's TLS certificate
and generate JWT keys if missing, create or update the agent's broker user,
migrate core and playback, restart.

Roll back one service: set `CORE_TAG=<commit sha>` (or another `*_TAG`) in
`.env` and deploy again.

## Agent

The agent connects with its own broker user over amqps (5671) and downloads
audio over HTTPS with its token. The broker's certificate comes from a private
CA issued on the first deploy, so the agent needs that CA's certificate:

```bash
docker compose cp rabbitmq:/etc/rabbitmq/tls/ca.crt ./ca.crt   # then copy it to the agent machine
```

On the agent machine, put `appsettings.Production.json` in the agent's folder
(values from the server's `.env`; backslashes in JSON are doubled):

```json
{
  "Agent": {
    "AmqpUri": "amqps://aeroflow-agent:<AGENT_RABBITMQ_PASSWORD>@<DOMAIN>:5671/%2f",
    "BrokerCaCertPath": "C:\\AeroFlow\\ca.crt",
    "CoreBaseUrl": "https://<DOMAIN>/",
    "CoreToken": "<AGENT_TOKEN>"
  }
}
```

The agent reads it on top of its `appsettings.json`. The file is not part of the
agent's build, so updating the agent keeps it; environment variables
(`AGENT_Agent__CoreToken=…`) still override it.

`ca.crt` is not a secret; the password and the token are, so make
`appsettings.Production.json` readable only to administrators and the account
that runs the agent.

The certificate is issued for `DOMAIN` once and kept in the `rabbitmq_tls`
volume. After changing
`DOMAIN`, remove that volume (`docker compose rm -sf rabbitmq`, `docker volume rm
aeroflow_rabbitmq_tls`), deploy again and copy the new `ca.crt` to the agent.
