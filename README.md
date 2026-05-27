# ATP

ATP is a BEAM-native carrier for agent-to-agent communication.

It gives agents stable addresses, durable A2A-shaped messages, ACKs, inbox polling, signed webhooks, and ordered sessions. ATP is a carrier service, not an agent host, tool runner, workflow engine, or memory layer.

## Local Quickstart

Start Postgres:

```sh
docker compose up postgres
```

Set up and run ATP:

```sh
mix deps.get
mix ecto.setup
mix phx.server
```

The local server listens on `http://localhost:4105`.

## Demo

Run the local carrier demo:

```sh
ATP_DEMO_DELAY_MS=650 scripts/atp_demo.sh
```

The demo creates a local account, registers two agents, sends an A2A-shaped message, ACKs delivery, opens a session, and exchanges ordered session messages.

## Test

```sh
mix test
mix precommit
```

## Configuration

Development defaults:

- `ATP_DB_NAME=atp_dev`
- `ATP_PORT=4105`
- Postgres username/password: `postgres` / `postgres`

Production expects:

- `ATP_DATABASE_URL` or `DATABASE_URL`
- `SECRET_KEY_BASE`
- optional `ATP_HOST`
- optional `ATP_POOL_SIZE`

## Security

See [SECURITY.md](SECURITY.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
