defmodule Atp.ArchitectureTest do
  use ExUnit.Case, async: true

  alias Atp.Transport.Ledger, as: TransportLedger

  test "ATP dependencies stay carrier scoped" do
    dep_apps =
      Atp.MixProject.project()
      |> Keyword.fetch!(:deps)
      |> Enum.map(fn
        {app, _requirement} -> app
        {app, _requirement, _opts} -> app
      end)

    assert dep_apps -- allowed_dependency_apps() == []
  end

  test "ATP lib code does not reference product-domain modules" do
    matches =
      "lib/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_number} -> line =~ product_domain_pattern() end)
        |> Enum.map(fn {line, line_number} -> "#{path}:#{line_number}: #{line}" end)
      end)

    assert matches == []
  end

  test "ATP production endpoint enforces SSL when served" do
    prod_config =
      __DIR__
      |> Path.join("../../config/prod.exs")
      |> Path.expand()
      |> Config.Reader.read!()

    endpoint_config = get_in(prod_config, [:atp, AtpWeb.Endpoint])

    assert Keyword.fetch!(endpoint_config, :force_ssl) == [rewrite_on: [:x_forwarded_proto]]
    assert Keyword.fetch!(endpoint_config, :exclude) == [hosts: ["localhost", "127.0.0.1"]]
  end

  test "ATP session runtime seam stays narrow" do
    runtime = Module.concat([Atp, Transport, Runtime])

    assert Code.ensure_loaded?(runtime)
    assert function_exported?(runtime, :open_session, 4)
    assert function_exported?(runtime, :accept_session, 5)
    assert function_exported?(runtime, :reject_session, 5)
    assert function_exported?(runtime, :send_session_message, 5)
    assert function_exported?(runtime, :get_session, 2)
    assert function_exported?(runtime, :ack_delivery, 5)
    assert function_exported?(runtime, :ensure_session_started, 1)
    assert function_exported?(runtime, :list_active_sessions, 0)

    assert runtime.__info__(:functions) |> Enum.sort() == [
             accept_session: 5,
             ack_delivery: 5,
             ensure_session_started: 1,
             get_session: 2,
             list_active_sessions: 0,
             open_session: 4,
             reject_session: 5,
             send_session_message: 5
           ]
  end

  test "ATP web controllers do not call runtime internals directly" do
    matches =
      "lib/atp_web/controllers/**/*_controller.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_number} -> String.contains?(line, "Transport.Runtime") end)
        |> Enum.map(fn {line, line_number} -> "#{path}:#{line_number}: #{line}" end)
      end)

    assert matches == []
  end

  test "Postgres durable ledger adapter owns webhook claim persistence" do
    postgres_source = File.read!("lib/atp/transport/durable_ledger/postgres.ex")

    assert postgres_source =~ "Atp.Repo"
    assert postgres_source =~ "Ecto.Query"
    assert postgres_source =~ "FOR UPDATE"
    assert postgres_source =~ "FOR UPDATE SKIP LOCKED"
    refute File.exists?("lib/atp/transport/delivery_claims.ex")
  end

  test "Postgres durable ledger adapter owns session accept mutation" do
    postgres_source = File.read!("lib/atp/transport/durable_ledger/postgres.ex")

    refute postgres_source =~ "Ledger.accept_session"
  end

  test "Postgres durable ledger adapter owns session reject mutation" do
    postgres_source = File.read!("lib/atp/transport/durable_ledger/postgres.ex")

    refute postgres_source =~ "Ledger.reject_session"
  end

  test "Postgres durable ledger adapter owns delivery ACK mutation" do
    postgres_source = File.read!("lib/atp/transport/durable_ledger/postgres.ex")
    legacy_ack_call = Enum.join(["Ledger", "ack_delivery"], ".")

    refute postgres_source =~ legacy_ack_call
  end

  test "Postgres durable ledger adapter owns polling lease mutations" do
    postgres_source = File.read!("lib/atp/transport/durable_ledger/postgres.ex")
    legacy_claim_call = Enum.join(["Ledger", "claim_inbox"], ".")
    legacy_extend_call = Enum.join(["Ledger", "extend_delivery"], ".")

    refute postgres_source =~ legacy_claim_call
    refute postgres_source =~ legacy_extend_call
  end

  test "runtime routes session lifecycle mutations through durable ledger" do
    runtime_source = File.read!("lib/atp/transport/runtime.ex")
    runtime_lines = String.split(runtime_source, "\n")

    assert runtime_source =~ "DurableLedger.accept_session"
    assert runtime_source =~ "DurableLedger.reject_session"

    refute Enum.any?(runtime_lines, &String.contains?(&1, "|> Ledger.accept_session"))
    refute Enum.any?(runtime_lines, &String.contains?(&1, "|> Ledger.reject_session"))
  end

  test "runtime routes delivery ACK mutation through durable ledger" do
    runtime_source = File.read!("lib/atp/transport/runtime.ex")
    runtime_lines = String.split(runtime_source, "\n")
    legacy_ack_pipe = "|> " <> Enum.join(["Ledger", "ack_delivery"], ".")

    assert runtime_source =~ "DurableLedger.ack_delivery"
    refute Enum.any?(runtime_lines, &String.contains?(&1, legacy_ack_pipe))
  end

  test "transport facade routes polling lease mutations through durable ledger" do
    transport_source = File.read!("lib/atp/transport.ex")

    assert transport_source =~ polling_delegate_pattern(:claim_inbox, :DurableLedger)
    assert transport_source =~ polling_delegate_pattern(:extend_delivery, :DurableLedger)
    refute transport_source =~ polling_delegate_pattern(:claim_inbox, :Ledger)
    refute transport_source =~ polling_delegate_pattern(:extend_delivery, :Ledger)
  end

  test "transport facade routes status reads and sender policy mutation through durable ledger" do
    transport_source = File.read!("lib/atp/transport.ex")

    assert transport_source =~ transport_delegate_pattern(:get_message_status, :DurableLedger)
    assert transport_source =~ transport_delegate_pattern(:upsert_sender_policy, :DurableLedger)
    refute transport_source =~ transport_delegate_pattern(:get_message_status, :Ledger)
    refute transport_source =~ transport_delegate_pattern(:upsert_sender_policy, :Ledger)
  end

  test "runtime routes session transcript reads through durable ledger" do
    runtime_source = File.read!("lib/atp/transport/runtime.ex")
    runtime_lines = String.split(runtime_source, "\n")

    assert runtime_source =~ "DurableLedger.get_session"

    refute Enum.any?(runtime_lines, fn line ->
             String.contains?(line, "Ledger.get_session") and
               not String.contains?(line, "DurableLedger.get_session")
           end)
  end

  test "legacy ledger does not expose session lifecycle entry points" do
    ledger_functions = TransportLedger.__info__(:functions)

    refute {:accept_session, 5} in ledger_functions
    refute {:reject_session, 5} in ledger_functions
  end

  test "legacy ledger does not expose delivery ACK entry point" do
    refute {:ack_delivery, 5} in TransportLedger.__info__(:functions)
  end

  test "legacy ledger does not expose polling lease entry points" do
    ledger_functions = TransportLedger.__info__(:functions)

    refute {:claim_inbox, 4} in ledger_functions
    refute {:extend_delivery, 5} in ledger_functions
  end

  test "Postgres durable ledger keeps ACK mutation in one state-machine flow" do
    postgres_source = File.read!("lib/atp/transport/durable_ledger/postgres.ex")

    assert postgres_source =~ "defp append_ack("
    assert postgres_source =~ "defp persist_ack("
    refute postgres_source =~ "defp persist_session_lifecycle_ack"
    refute postgres_source =~ "defp validate_lifecycle_ack_lease"
    refute postgres_source =~ "defp validate_delivery_ack_lease"
    refute postgres_source =~ "defp cache_opening_session_lifecycle"
    refute postgres_source =~ "defp cache_opening_session_delivery_ack"
  end

  test "session intake completion does not reload Postgres session rows" do
    session_intake_source = File.read!("lib/atp/transport/session_intake.ex")

    refute session_intake_source =~ "Atp.Repo"
    refute session_intake_source =~ "Repo.get!"
  end

  defp allowed_dependency_apps do
    [
      :bandit,
      :boundary,
      :credo,
      :ecto_sql,
      :jason,
      :mix_audit,
      :phoenix,
      :phoenix_ecto,
      :plug_crypto,
      :postgrex,
      :req,
      :sobelow,
      :tidewave
    ]
  end

  defp product_domain_pattern do
    ~r/\b(SourceMonitor|RLM|MarketEvents|Billing|Corpus|Missions)\b/
  end

  defp polling_delegate_pattern(:claim_inbox, module) do
    ~r/defdelegate\s+claim_inbox\(agent,\s*params,\s*idempotency_key,\s*route\),\s*to:\s*#{module}/
  end

  defp polling_delegate_pattern(:extend_delivery, module) do
    ~r/defdelegate\s+extend_delivery\(agent,\s*delivery_id,\s*params,\s*idempotency_key,\s*route\),\s*to:\s*#{module}/
  end

  defp transport_delegate_pattern(:get_message_status, module) do
    ~r/defdelegate\s+get_message_status\(agent,\s*message_id\),\s*to:\s*#{module}/
  end

  defp transport_delegate_pattern(:upsert_sender_policy, module) do
    ~r/defdelegate\s+upsert_sender_policy\(recipient,\s*agent_id,\s*params,\s*idempotency_key,\s*route\),\s*to:\s*#{module}/
  end
end
