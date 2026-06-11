defmodule Atp.ReadinessTest do
  use Atp.DataCase, async: true

  alias Atp.Readiness
  alias Atp.Transport.WebhookDispatcher

  @database_schema_requirements [
    {"atp_accounts", "accounts", ~w(id name plan inserted_at updated_at)},
    {"atp_account_api_keys", "account_api_keys",
     ~w(id account_id label token_hash last_used_at revoked_at inserted_at updated_at)},
    {"atp_agents", "agents",
     ~w(id account_id address display_name description status webhook_url webhook_secret webhook_active inserted_at updated_at)},
    {"atp_agent_api_keys", "agent_api_keys",
     ~w(id account_id agent_id label token_hash last_used_at revoked_at inserted_at updated_at)},
    {"atp_idempotency_keys", "idempotency_keys",
     ~w(id account_id key route request_hash response_status response_body principal_type principal_id inserted_at)},
    {"atp_messages", "messages",
     ~w(id sender_account_id recipient_account_id sender_agent_id recipient_agent_id sender_address recipient_address trust payload content_type carrier_status current_ack_status terminal_at expires_at inserted_at updated_at session_id session_sequence)},
    {"atp_deliveries", "deliveries",
     ~w(id message_id recipient_agent_id mode status leased_until inserted_at updated_at attempt_count max_attempts next_attempt_at delivered_at last_error claim_token claimed_at)},
    {"atp_acks", "acks",
     ~w(id message_id delivery_id recipient_agent_id status payload inserted_at)},
    {"atp_sessions", "sessions",
     ~w(id initiator_account_id recipient_account_id initiator_agent_id recipient_agent_id initiator_address recipient_address status opening_message_id last_sequence opened_at terminal_at inserted_at updated_at)},
    {"atp_agent_sender_policies", "sender_policies",
     ~w(id recipient_agent_id sender_agent_id sender_account_id effect inserted_at updated_at)},
    {"atp_webhook_attempts", "webhook_attempts",
     ~w(id delivery_id message_id recipient_agent_id attempt_number request_url response_status error result next_attempt_at inserted_at)}
  ]

  defmodule RecordingRepo do
    def query(sql, params, opts) do
      send(self(), {:readiness_query, sql, params, opts})
      {:ok, %{columns: [], rows: []}}
    end
  end

  defmodule FailingRepo do
    def query(_sql, _params, _opts) do
      {:error, {:database_url, "ecto://secret@example.test/atp", self()}}
    end
  end

  defmodule RaisingRepo do
    def query(_sql, _params, _opts) do
      raise "leaked database exception"
    end
  end

  defmodule ThrowingRepo do
    def query(_sql, _params, _opts) do
      throw({:leaked_database_throw, "ecto://secret@example.test/atp"})
    end
  end

  defmodule RaisingRegistry do
    def whereis_name(_name), do: raise("leaked registry exception")
  end

  defmodule ThrowingRegistry do
    def whereis_name(_name), do: throw({:leaked_registry_throw, "#PID<0.0.0>"})
  end

  test "uses default configured checks" do
    assert Readiness.check() == %{
             "status" => "ok",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "disabled"
             }
           }
  end

  test "reports ready when database runtime and enabled dispatcher are available" do
    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true, dispatch_on_start?: false, interval_ms: 60_000, name: nil}
      )

    assert Readiness.check(
             webhook_dispatcher_config: [enabled: true],
             webhook_dispatcher_server: dispatcher
           ) ==
             %{
               "status" => "ok",
               "checks" => %{
                 "database" => "ok",
                 "transport_runtime" => "ok",
                 "webhook_dispatcher" => "ok"
               }
             }
  end

  test "uses configured dispatcher name when no server override is provided" do
    name = :atp_readiness_named_dispatcher

    start_supervised!(
      {WebhookDispatcher,
       enabled: true, dispatch_on_start?: false, interval_ms: 60_000, name: name}
    )

    assert Readiness.check(
             repo: RecordingRepo,
             webhook_dispatcher_config: [enabled: true, name: name]
           ) == %{
             "status" => "ok",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "ok"
             }
           }
  end

  test "uses configured via dispatcher name when no server override is provided" do
    registry = :"atp_readiness_dispatcher_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    name = {:via, Registry, {registry, :dispatcher}}

    start_supervised!(
      {WebhookDispatcher,
       enabled: true, dispatch_on_start?: false, interval_ms: 60_000, name: name}
    )

    assert Readiness.check(
             repo: RecordingRepo,
             webhook_dispatcher_config: [enabled: true, name: name]
           ) == %{
             "status" => "ok",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "ok"
             }
           }
  end

  test "uses configured global dispatcher name when no server override is provided" do
    name = {:global, {:atp_readiness_global_dispatcher, System.unique_integer([:positive])}}

    start_supervised!(
      {WebhookDispatcher,
       enabled: true, dispatch_on_start?: false, interval_ms: 60_000, name: name}
    )

    assert Readiness.check(
             repo: RecordingRepo,
             webhook_dispatcher_config: [enabled: true, name: name]
           ) == %{
             "status" => "ok",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "ok"
             }
           }
  end

  test "database check uses a cheap schema-sensitive query without logging details" do
    assert Readiness.check(
             repo: RecordingRepo,
             webhook_dispatcher_config: [enabled: false]
           ) == %{
             "status" => "ok",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "disabled"
             }
           }

    assert_received {:readiness_query, sql, [], opts}

    for {table_name, table_alias, columns} <- @database_schema_requirements do
      assert sql =~ "#{table_name} AS #{table_alias}"

      for column <- columns do
        assert sql =~ "#{table_alias}.#{column}"
      end
    end

    assert sql =~ "LIMIT 0"
    assert opts[:log] == false
  end

  test "disabled webhook dispatcher is reported as disabled and does not fail readiness" do
    assert Readiness.check(webhook_dispatcher_config: [enabled: false]) == %{
             "status" => "ok",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "disabled"
             }
           }
  end

  test "invalid dispatcher configuration is sanitized to unavailable" do
    assert Readiness.check(
             repo: RecordingRepo,
             webhook_dispatcher_config: :invalid,
             webhook_dispatcher_server: nil
           ) == %{
             "status" => "error",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "error"
             }
           }

    assert Readiness.check(
             repo: RecordingRepo,
             webhook_dispatcher_config: [enabled: true],
             webhook_dispatcher_server: "not a process name"
           ) == %{
             "status" => "error",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "error"
             }
           }
  end

  test "enabled but unavailable webhook dispatcher fails readiness" do
    assert Readiness.check(
             repo: RecordingRepo,
             webhook_dispatcher_config: [enabled: true],
             webhook_dispatcher_server: :missing_readiness_dispatcher
           ) == %{
             "status" => "error",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "error"
             }
           }
  end

  test "unavailable transport runtime fails readiness" do
    assert Readiness.check(
             repo: RecordingRepo,
             transport_runtime_supervisor: :missing_readiness_runtime,
             webhook_dispatcher_config: [enabled: false]
           ) == %{
             "status" => "error",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "error",
               "webhook_dispatcher" => "disabled"
             }
           }
  end

  test "database failures are sanitized to coarse public output" do
    result =
      Readiness.check(
        repo: FailingRepo,
        transport_runtime_supervisor: :missing_readiness_runtime,
        webhook_dispatcher_config: [enabled: true],
        webhook_dispatcher_server: :missing_readiness_dispatcher
      )

    assert result == %{
             "status" => "error",
             "checks" => %{
               "database" => "error",
               "transport_runtime" => "error",
               "webhook_dispatcher" => "error"
             }
           }

    public_output = inspect(result)
    refute public_output =~ "ecto://"
    refute public_output =~ "secret"
    refute public_output =~ "atp_deliveries"
    refute public_output =~ "SELECT"
    refute public_output =~ "#PID"
  end

  test "database exceptions and throws are sanitized to coarse public output" do
    for repo <- [RaisingRepo, ThrowingRepo] do
      result =
        Readiness.check(
          repo: repo,
          webhook_dispatcher_config: [enabled: false]
        )

      assert result == %{
               "status" => "error",
               "checks" => %{
                 "database" => "error",
                 "transport_runtime" => "ok",
                 "webhook_dispatcher" => "disabled"
               }
             }

      public_output = inspect(result)
      refute public_output =~ "ecto://"
      refute public_output =~ "leaked"
    end
  end

  test "dispatcher registry lookup exceptions and throws are sanitized" do
    for registry <- [RaisingRegistry, ThrowingRegistry] do
      result =
        Readiness.check(
          repo: RecordingRepo,
          webhook_dispatcher_config: [enabled: true],
          webhook_dispatcher_server: {:via, registry, :dispatcher}
        )

      assert result == %{
               "status" => "error",
               "checks" => %{
                 "database" => "ok",
                 "transport_runtime" => "ok",
                 "webhook_dispatcher" => "error"
               }
             }

      public_output = inspect(result)
      refute public_output =~ "leaked"
      refute public_output =~ "#PID"
    end
  end
end
