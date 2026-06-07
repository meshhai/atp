defmodule Atp.ArchitectureTest do
  use ExUnit.Case, async: true

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
    postgres_lines = String.split(postgres_source, "\n")

    refute legacy_call?(postgres_lines, "accept_session")
  end

  test "Postgres durable ledger adapter owns session reject mutation" do
    postgres_source = File.read!("lib/atp/transport/durable_ledger/postgres.ex")
    postgres_lines = String.split(postgres_source, "\n")

    refute legacy_call?(postgres_lines, "reject_session")
  end

  test "Postgres durable ledger adapter owns delivery ACK mutation" do
    postgres_source = File.read!("lib/atp/transport/durable_ledger/postgres.ex")
    postgres_lines = String.split(postgres_source, "\n")

    refute legacy_call?(postgres_lines, "ack_delivery")
  end

  test "Postgres durable ledger adapter owns polling lease mutations" do
    postgres_source = File.read!("lib/atp/transport/durable_ledger/postgres.ex")
    postgres_lines = String.split(postgres_source, "\n")

    refute legacy_call?(postgres_lines, "claim_inbox")
    refute legacy_call?(postgres_lines, "extend_delivery")
  end

  test "runtime routes session lifecycle mutations through durable ledger" do
    runtime_source = File.read!("lib/atp/transport/runtime.ex")
    runtime_lines = String.split(runtime_source, "\n")

    assert runtime_source =~ "DurableLedger.accept_session"
    assert runtime_source =~ "DurableLedger.reject_session"

    refute legacy_call?(runtime_lines, "accept_session")
    refute legacy_call?(runtime_lines, "reject_session")
  end

  test "runtime routes delivery ACK mutation through durable ledger" do
    runtime_source = File.read!("lib/atp/transport/runtime.ex")
    runtime_lines = String.split(runtime_source, "\n")

    assert runtime_source =~ "DurableLedger.ack_delivery"
    refute legacy_call?(runtime_lines, "ack_delivery")
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

    refute legacy_call?(runtime_lines, "get_session")
  end

  test "runtime routes session helper reads through durable ledger" do
    runtime_source = File.read!("lib/atp/transport/runtime.ex")
    session_server_source = File.read!("lib/atp/transport/runtime/session_server.ex")
    rehydrator_source = File.read!("lib/atp/transport/runtime/pending_session_rehydrator.ex")
    runtime_lines = String.split(runtime_source, "\n")
    session_server_lines = String.split(session_server_source, "\n")
    rehydrator_lines = String.split(rehydrator_source, "\n")

    assert runtime_source =~ "DurableLedger.fetch_open_session"
    assert runtime_source =~ "DurableLedger.opening_session_id_for_delivery"
    assert session_server_source =~ "DurableLedger.fetch_runtime_session"
    assert rehydrator_source =~ "DurableLedger.list_pending_session_ids"

    refute legacy_call?(runtime_lines, "fetch_open_session")
    refute legacy_call?(runtime_lines, "opening_session_id_for_delivery")
    refute legacy_call?(session_server_lines, "fetch_runtime_session")
    refute legacy_call?(rehydrator_lines, "list_pending_session_ids")
  end

  test "legacy transport ledger module is removed" do
    refute File.exists?("lib/atp/transport/ledger.ex")
    refute Code.ensure_loaded?(legacy_transport_ledger_module())
  end

  test "source code does not reference the legacy transport ledger" do
    matches =
      legacy_reference_paths()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_number} -> legacy_transport_ledger_reference?(line) end)
        |> Enum.map(fn {line, line_number} -> "#{path}:#{line_number}: #{line}" end)
      end)

    assert matches == []
  end

  test "session runtime routes pending opening expiry through durable ledger" do
    session_server_source = File.read!("lib/atp/transport/runtime/session_server.ex")
    session_server_lines = String.split(session_server_source, "\n")

    assert session_server_source =~ "DurableLedger.expire_pending_opening_session"
    refute legacy_call?(session_server_lines, "expire_pending_opening_session")
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
      :telemetry,
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

  defp legacy_call?(lines, function_name) do
    legacy_call = Enum.join(["Ledger", function_name], ".")

    Enum.any?(lines, fn line ->
      String.contains?(line, legacy_call) and
        not String.contains?(line, "Durable" <> legacy_call)
    end)
  end

  defp legacy_transport_ledger_module do
    Module.concat([Atp, Transport, "Ledger"])
  end

  defp legacy_reference_paths do
    ["lib/**/*.{ex,exs}", "test/**/*.{ex,exs}"]
    |> Enum.flat_map(&Path.wildcard/1)
  end

  defp legacy_transport_ledger_reference?(line) do
    String.contains?(line, legacy_transport_ledger_name()) or
      Regex.match?(legacy_ledger_call_pattern(), line)
  end

  defp legacy_transport_ledger_name do
    Enum.join(["Atp", "Transport", "Ledger"], ".")
  end

  defp legacy_ledger_call_pattern do
    legacy_call = "Ledger" <> "."
    Regex.compile!("(^|[^[:alnum:]_])" <> Regex.escape(legacy_call))
  end
end
