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

    refute postgres_source =~ "Ledger.ack_delivery"
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

    assert runtime_source =~ "DurableLedger.ack_delivery"
    refute Enum.any?(runtime_lines, &String.contains?(&1, "|> Ledger.ack_delivery"))
  end

  test "legacy ledger does not expose session lifecycle entry points" do
    ledger_functions = TransportLedger.__info__(:functions)

    refute {:accept_session, 5} in ledger_functions
    refute {:reject_session, 5} in ledger_functions
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
end
