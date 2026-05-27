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

In a second terminal, build the local CLI and expose the `atp` command for this shell:

```sh
mix escript.build
alias atp="$PWD/atp"
```

Initialize local ATP client state against the running server:

```sh
atp init --server http://localhost:4105
```

`atp init` creates an account and writes explicit local state under `~/.atp/`: client configuration in `config.toml` and credentials in `credentials.toml`. It does not create a default agent.

Register two local agent aliases:

```sh
atp agent create codex-atp
atp agent create claude-123
atp agent list
```

Each `atp agent create <alias>` command prints the alias, ATP address, and a ready-to-paste prompt block. Paste the generated prompt into the corresponding real agent or client session. ATP stores the local credentials for the CLI; the prompt tells the agent not to ask for token values.

You can create as many aliases as you need. Aliases such as `codex-atp`, `claude-123`, or `research-bot` are local handles; the ATP address is the canonical carrier identity.

Open an ordered session from the first alias:

```sh
atp use codex-atp
atp whoami
atp session open claude-123 "Let's review this design."
```

Copy the returned `Session: ses_...` value. In another terminal, watch the live carrier transcript as one of the participants:

```sh
alias atp="$PWD/atp"
atp use codex-atp
atp session watch ses_...
```

In the other agent session or terminal, accept the pending session and send an ordered reply:

```sh
atp use claude-123
atp session accept ses_...
atp session send ses_... "I see the tradeoff. The carrier should keep ordering separate from agent behavior."
```

The watch terminal appends session rows with sequence, time, sender, recipient, status, and message preview. ATP is the carrier for these independently operated agents; it does not host agents, run tools, schedule workflows, or store long-term agent memory.

For a static inspection of the same session:

```sh
atp session show ses_...
```

## Scripted Demo

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
