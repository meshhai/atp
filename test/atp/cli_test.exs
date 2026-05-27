defmodule Atp.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Plug.Conn

  @account_token "ak_test_account_token"
  @agent_token "agk_test_agent_token"

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "atp-cli-test-#{System.unique_integer([:positive])}")
    atp_home = Path.join(tmp_dir, ".atp")

    previous_home = System.get_env("ATP_HOME")
    previous_cli_config = Application.get_env(:atp, Atp.CLI)

    System.put_env("ATP_HOME", atp_home)
    Application.put_env(:atp, Atp.CLI, req_options: [plug: {Req.Test, __MODULE__}])

    on_exit(fn ->
      restore_env("ATP_HOME", previous_home)
      restore_app_env(previous_cli_config)
      File.rm_rf!(tmp_dir)
    end)

    %{atp_home: atp_home}
  end

  setup {Req.Test, :verify_on_exit!}

  test "init creates local state, creates an account, and points to agent registration", %{
    atp_home: atp_home
  } do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/accounts"

      assert Jason.decode!(Req.Test.raw_body(conn)) == %{"name" => "ATP CLI Account"}

      Req.Test.json(conn, %{
        "id" => "acct_test",
        "name" => "ATP CLI Account",
        "plan" => "free",
        "account_api_key" => %{
          "id" => "acctkey_test",
          "token" => @account_token
        }
      })
    end)

    output = capture_io(fn -> assert Atp.CLI.run(["init"]) == 0 end)

    config_path = Path.join(atp_home, "config.toml")
    credentials_path = Path.join(atp_home, "credentials.toml")

    assert output =~ "Config: #{config_path}"
    assert output =~ "Credentials: #{credentials_path}"
    assert output =~ "No default agent was created."
    assert output =~ "Next: atp agent create <alias>"
    refute output =~ @account_token

    assert File.read!(config_path) =~ ~s(server_url = "http://localhost:4105")
    assert File.read!(credentials_path) =~ ~s(account_token = "#{@account_token}")
    assert owner_only?(credentials_path)
  end

  test "agent create stores alias credentials and prints a token-safe agent prompt", %{
    atp_home: atp_home
  } do
    seed_initialized_state!(atp_home)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/agents"
      assert get_req_header(conn, "authorization") == ["Bearer #{@account_token}"]
      assert get_req_header(conn, "idempotency-key") == ["cli-agent-create-codex-atp"]

      assert Jason.decode!(Req.Test.raw_body(conn)) == %{
               "display_name" => "codex-atp",
               "description" => "ATP CLI local alias codex-atp"
             }

      Req.Test.json(conn, %{
        "id" => "agt_codex",
        "address" => "atp://agent/agt_codex",
        "display_name" => "codex-atp",
        "description" => "ATP CLI local alias codex-atp",
        "active_agent_key_id" => "agtkey_codex",
        "agent_api_key" => %{
          "id" => "agtkey_codex",
          "token" => @agent_token
        }
      })
    end)

    output = capture_io(fn -> assert Atp.CLI.run(["agent", "create", "codex-atp"]) == 0 end)

    assert output =~ "Alias: codex-atp"
    assert output =~ "Address: atp://agent/agt_codex"
    assert output =~ "Do not ask for ATP tokens"
    assert output =~ "atp use codex-atp"
    refute output =~ @agent_token

    config = File.read!(Path.join(atp_home, "config.toml"))
    credentials = File.read!(Path.join(atp_home, "credentials.toml"))

    assert config =~ ~s([aliases."codex-atp"])
    assert config =~ ~s(address = "atp://agent/agt_codex")
    assert credentials =~ ~s([agents."codex-atp"])
    assert credentials =~ ~s(agent_token = "#{@agent_token}")
  end

  test "agent list, use, and whoami work from local config", %{atp_home: atp_home} do
    seed_initialized_state!(atp_home)
    seed_agent!(atp_home, "codex-atp")

    list_output = capture_io(fn -> assert Atp.CLI.run(["agent", "list"]) == 0 end)

    assert list_output =~ "codex-atp"
    assert list_output =~ "atp://agent/agt_codex_atp"

    use_output = capture_io(fn -> assert Atp.CLI.run(["use", "codex-atp"]) == 0 end)

    assert use_output =~ "Active alias: codex-atp"
    assert use_output =~ "Address: atp://agent/agt_codex_atp"

    whoami_output = capture_io(fn -> assert Atp.CLI.run(["whoami"]) == 0 end)

    assert whoami_output =~ "Alias: codex-atp"
    assert whoami_output =~ "Address: atp://agent/agt_codex_atp"
  end

  defp seed_initialized_state!(atp_home) do
    File.mkdir_p!(atp_home)

    File.write!(Path.join(atp_home, "config.toml"), """
    server_url = "http://localhost:4105"
    active_alias = ""
    """)

    credentials_path = Path.join(atp_home, "credentials.toml")

    File.write!(credentials_path, """
    account_id = "acct_test"
    account_key_id = "acctkey_test"
    account_token = "#{@account_token}"
    """)

    File.chmod!(credentials_path, 0o600)
  end

  defp seed_agent!(atp_home, alias) do
    config_path = Path.join(atp_home, "config.toml")
    credentials_path = Path.join(atp_home, "credentials.toml")
    suffix = String.replace(alias, "-", "_")

    File.write!(config_path, """
    #{File.read!(config_path)}
    [aliases."#{alias}"]
    agent_id = "agt_#{suffix}"
    address = "atp://agent/agt_#{suffix}"
    """)

    File.write!(credentials_path, """
    #{File.read!(credentials_path)}
    [agents."#{alias}"]
    agent_key_id = "agtkey_#{suffix}"
    agent_token = "agk_#{suffix}"
    """)

    File.chmod!(credentials_path, 0o600)
  end

  defp owner_only?(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o077) == 0
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(nil), do: Application.delete_env(:atp, Atp.CLI)
  defp restore_app_env(value), do: Application.put_env(:atp, Atp.CLI, value)
end
