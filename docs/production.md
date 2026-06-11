# Single-Node Production Operations

ATP is the Agent Transfer Protocol: a carrier service for durable agent-to-agent
message delivery. It gives agents stable addresses, durable messages, delivery
records, ACKs, inbox polling, signed webhooks, sender policy, and ordered
sessions.

ATP is not an agent host, tool runner, workflow engine, scheduler, downstream
product service, or long-term memory layer. Agent behavior and product-specific
state stay outside ATP.

## Production Contract

The current production contract is single-node:

- one Phoenix service instance
- one Postgres durable ledger
- local BEAM/OTP runtime processes on that service instance

The durable ledger is the source of truth for carrier state. The BEAM live plane
owns active carrier operations such as session processes, per-session ordering,
timers, and webhook dispatch work. If the service restarts, runtime processes
rehydrate from persisted ledger state.

Multi-node runtime operation is not part of the current contract. Do not deploy
multiple active ATP service instances against one ledger unless a later
architecture decision explicitly defines that mode.

Docker Compose remains local development guidance. A production deployment
should provide a production Postgres database, stable secret configuration, TLS
termination, migration execution, and process supervision through the operator's
VM, container, or platform tooling.

## Required Configuration

Set these values for a production node that serves HTTP traffic:

- `MIX_ENV=prod`: runs the production configuration.
- `PHX_SERVER=true`: starts the Phoenix endpoint for release-style starts.
- `ATP_DATABASE_URL` or `DATABASE_URL`: Ecto/Postgres connection URL. ATP treats
  Postgres as the current production durable ledger implementation.
- `SECRET_KEY_BASE`: Phoenix secret key base and ATP idempotency response secret.
  Generate it with `mix phx.gen.secret`.

`ATP_DATABASE_URL` takes precedence over `DATABASE_URL` when both are set.

The database user must be able to connect, read and write ATP tables, and run
the deployed migration set during the migration step.

## Optional Configuration

The current production runtime also supports these environment variables:

- `ATP_HOST`: public host used in the Phoenix endpoint URL. Defaults to
  `localhost`.
- `ATP_PORT`: HTTP port for the endpoint listener. Defaults to `4000`.
- `ATP_POOL_SIZE` or `POOL_SIZE`: database connection pool size. `ATP_POOL_SIZE`
  takes precedence. Defaults to `10`.
- `ECTO_IPV6=true` or `ECTO_IPV6=1`: enables IPv6 socket options for Ecto.

Webhook dispatcher behavior is configured through the OTP application
environment for `Atp.Transport.WebhookDispatcher`, not through a production env
var today. By default the dispatcher is enabled. If an operator intentionally
sets it to disabled application config, readiness reports the dispatcher as
`disabled` and the node can still be ready for non-dispatch work.

Development and test variables such as `ATP_DB_NAME`, `PGUSER`, `PGPASSWORD`,
`PGHOST`, `TEST_POOL_SIZE`, and `ATP_BIND_ALL` are for local workflows, not the
production contract.

## Database Migrations

ATP does not run migrations from request handling or readiness checks. Run
migrations explicitly before promoting traffic to a new version.

For source-based deployments, the migration command is:

```sh
MIX_ENV=prod mix ecto.migrate
```

For release-based deployments, run the deployment's Ecto migration command
against the same release and database before the instance receives traffic.

Operationally, a deployment should follow this order:

1. Start from a tested build artifact.
2. Apply database migrations against the target ledger.
3. Start or restart the ATP service process.
4. Wait for `GET /ready` to return `200`.
5. Promote traffic to the instance.

If migrations are missing or incompatible, readiness should fail through the
database check before the node receives carrier work.

## Probes

ATP exposes unauthenticated root-level JSON probes:

- `GET /health`
- `GET /ready`

They are intentionally outside `/api` and do not require account or agent
credentials.

### `GET /health`

`/health` answers whether Phoenix can respond to an HTTP request.

Successful response:

```json
{"status":"ok"}
```

The endpoint returns HTTP `200` when the process can serve the request. It does
not inspect the database, runtime supervision tree, webhook dispatcher, carrier
state, or downstream systems.

### `GET /ready`

`/ready` answers whether this single node is safe to receive ATP carrier
traffic.

Ready response:

```json
{
  "status": "ok",
  "checks": {
    "database": "ok",
    "transport_runtime": "ok",
    "webhook_dispatcher": "ok"
  }
}
```

Not-ready response:

```json
{
  "status": "error",
  "checks": {
    "database": "error",
    "transport_runtime": "ok",
    "webhook_dispatcher": "ok"
  }
}
```

HTTP semantics:

- `200`: all required checks are `ok`, or the webhook dispatcher is intentionally
  `disabled`.
- `503`: at least one required check is `error`.

Readiness checks:

- database usability with a cheap schema-sensitive query over ATP carrier
  tables
- transport runtime supervisor availability
- webhook dispatcher availability when dispatcher config is enabled

If the dispatcher is intentionally disabled, the dispatcher check reports
`disabled` and does not fail readiness.

Readiness intentionally does not check:

- recipient webhook reachability
- agent availability
- queue emptiness
- backlog depth
- downstream product health
- external dependencies other than the configured durable ledger
- multi-node health

## Public Probe Data

Probe responses are coarse and public. They must not expose database URLs,
database names, SQL text, adapter errors, environment variables, PIDs, node
names, migration versions, exception text, delivery IDs, message IDs, webhook
URLs, tokens, queue depths, agent data, or message payload content.

Treat probes as load balancer and process manager signals, not diagnostic
endpoints. Use logs, telemetry, database inspection, or an operator console for
private debugging.
