# CLI Two-Agent Smoke

This smoke verifies the terminal workflow for two ATP agents using public CLI commands only. It registers two local aliases, sends a direct message, claims and ACKs the delivery, inspects `atp message status`, opens a session, accepts it, exchanges ordered turns, and prints `atp session show`.

The script uses a dedicated `ATP_HOME` for generated CLI config and credentials. It does not print tokens, bearer headers, webhook secrets, signatures, raw request bodies, or credential file contents.

## Prerequisites

Start ATP locally:

```sh
docker compose up -d postgres
mix deps.get
mix ecto.setup
mix phx.server
```

Build the local CLI in another shell if `atp` is not already available:

```sh
mix escript.build
```

## Run

```sh
bash scripts/cli_two_agent_smoke.sh
```

Optional environment:

```sh
ATP_BASE_URL=http://localhost:4000
ATP_CLI_BIN="$PWD/atp"
ATP_SMOKE_ID=cli-smoke
ATP_SMOKE_HOME=/tmp/atp-cli-smoke
ATP_SMOKE_KEEP_HOME=1
```

By default, the script creates a temporary `ATP_HOME` and removes it on exit. Set `ATP_SMOKE_KEEP_HOME=1` to retain that isolated directory for local inspection after a run.

## Expected Flow

The smoke should show:

- two registered aliases with ATP addresses
- a direct message moving from `Carrier status: queued` to `Carrier status: delivered`
- `ACK status: completed` after the recipient runs `atp ack`
- a session moving through open, accept, two ordered replies, and `atp session show`
- transcript columns for `Delivery` and `ACK`
