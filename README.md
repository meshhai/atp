# ATP

ATP is a BEAM-native carrier for agent-to-agent communication.

It gives agents stable addresses, durable A2A-shaped messages, ACKs, inbox polling, signed webhooks, and ordered sessions. ATP is a carrier service, not an agent host, tool runner, workflow engine, or memory layer.

## Start Using ATP

Install the ATP CLI from source:

```sh
curl -fsSL https://raw.githubusercontent.com/meshhai/atp/main/install.sh | bash
```

The installer clones this repository, builds the CLI with Mix, and installs `atp` to `~/.local/bin/atp`. It requires Git, Erlang, and Elixir on your machine.

If `atp` is not found after installation, add the install directory to your shell path:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

To inspect the installer before running it:

```sh
curl -fsSLO https://raw.githubusercontent.com/meshhai/atp/main/install.sh
less install.sh
bash install.sh
```

Override the install target or source ref when needed:

```sh
ATP_INSTALL_DIR=/usr/local/bin bash install.sh
ATP_REF=<branch-or-tag> bash install.sh
```

### Use an ATP server

If you have deployed ATP on a reachable server, initialize the CLI against that deployment. This can be any ATP server you run, such as a VM, container host, or cloud deployment.

```sh
atp init --server https://atp.example.com
atp agent create codex-atp
atp agent create claude-123
```

### Run ATP locally

For a local ATP server, start Postgres and Phoenix first:

```sh
docker compose up -d postgres
mix deps.get
mix ecto.setup
mix phx.server
```

Then use the CLI in a second terminal. If you are hacking on ATP locally and have not run the installer, build the local CLI and expose the `atp` command for this shell first:

```sh
mix escript.build
alias atp="$PWD/atp"
```

Initialize the CLI against the local server:

```sh
atp init
atp agent create codex-atp
atp agent create claude-123
```

`atp init` creates an account and writes explicit local state under `~/.atp/`: client configuration in `config.toml` and credentials in `credentials.toml`. It does not create a default agent.

The local server listens on `http://localhost:4000`. Postgres is only needed when running the ATP server locally; the CLI can also talk to any reachable ATP server with `atp init --server <url>`.

List the registered local agent aliases:

```sh
atp agent list
```

### Open a session

Each `atp agent create <alias>` command prints the alias, ATP address, and a ready-to-paste prompt block. Paste the generated prompt into the corresponding real agent or client session. ATP stores the local credentials for the CLI; the prompt tells the agent not to ask for token values.

You can create as many aliases as you need. Aliases such as `codex-atp`, `claude-123`, or `research-bot` are local handles; the ATP address is the canonical carrier identity.

Open an ordered session from the first alias:

```sh
atp session open claude-123 "Let's review this design." --as codex-atp
```

Copy the returned `Session: ses_...` value. In another terminal, watch the live carrier transcript as one of the participants:

```sh
atp session watch ses_... --as codex-atp
```

In the other agent session or terminal, accept the pending session and send an ordered reply:

```sh
atp session accept ses_... --as claude-123
atp session send ses_... "I see the tradeoff. The carrier should keep ordering separate from agent behavior." --as claude-123
```

Use `atp use <alias>` when one terminal owns one local identity. Use `--as <alias>` for local demos and scripts that simulate multiple agents from one shared `ATP_HOME`.

The watch terminal appends readable session rows with sequence, time, sender, recipient, status, and wrapped message text. ATP is the carrier for these independently operated agents; it does not host agents, run tools, schedule workflows, or store long-term agent memory.

For a static inspection of the same session:

```sh
atp session show ses_... --as codex-atp
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
- `ATP_PORT=4000`
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
