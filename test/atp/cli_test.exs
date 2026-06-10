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

    assert File.read!(config_path) =~ ~s(server_url = "http://localhost:4000")
    assert File.read!(credentials_path) =~ ~s(account_token = "#{@account_token}")
    assert owner_only?(credentials_path)
  end

  test "agent create stores alias credentials and prints a token-safe agent prompt", %{
    atp_home: atp_home
  } do
    seed_initialized_state!(atp_home)
    File.chmod!(Path.join(atp_home, "credentials.toml"), 0o644)

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
    assert owner_only?(Path.join(atp_home, "credentials.toml"))
  end

  test "agent create fails closed when credential permissions cannot be set", %{
    atp_home: atp_home
  } do
    seed_initialized_state!(atp_home)

    Application.put_env(:atp, Atp.CLI,
      req_options: [plug: {Req.Test, __MODULE__}],
      credential_chmod: fn _path, 0o600 -> {:error, :eperm} end
    )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/agents"

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

    stderr =
      capture_io(:stderr, fn ->
        assert Atp.CLI.run(["agent", "create", "codex-atp"]) == 1
      end)

    credentials = File.read!(Path.join(atp_home, "credentials.toml"))

    assert stderr =~ "could not set owner-only permissions"
    refute credentials =~ @agent_token
    refute Enum.any?(File.ls!(atp_home), &String.contains?(&1, ".tmp-"))
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

  test "send, inbox, and completed ACK use aliases and stored agent credentials", %{
    atp_home: atp_home
  } do
    seed_initialized_state!(atp_home)
    seed_agent!(atp_home, "codex-atp")
    seed_agent!(atp_home, "claude-123")
    seed_active_alias!(atp_home, "codex-atp")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/messages"
      assert get_req_header(conn, "authorization") == ["Bearer agk_codex_atp"]
      assert [send_key] = get_req_header(conn, "idempotency-key")
      assert String.starts_with?(send_key, "cli-send-")

      assert %{
               "to" => "atp://agent/agt_claude_123",
               "payload" => %{
                 "messageId" => send_message_id,
                 "role" => "ROLE_USER",
                 "parts" => [%{"text" => "hello from codex"}]
               }
             } = Jason.decode!(Req.Test.raw_body(conn))

      assert String.starts_with?(send_message_id, "cli-msg-")

      conn
      |> put_status(201)
      |> Req.Test.json(%{
        "message" => %{
          "id" => "msg_cli_send",
          "from" => "atp://agent/agt_codex_atp",
          "to" => "atp://agent/agt_claude_123",
          "created_at" => "2026-05-27T12:00:00Z",
          "payload" => %{
            "messageId" => send_message_id,
            "role" => "ROLE_USER",
            "parts" => [%{"text" => "hello from codex"}]
          }
        },
        "carrier_status" => "queued",
        "ack_status" => nil,
        "terminal_at" => nil,
        "deliveries" => []
      })
    end)

    send_output =
      capture_io(fn ->
        assert Atp.CLI.run(["send", "claude-123", "hello from codex"]) == 0
      end)

    assert send_output =~ "Sender: codex-atp"
    assert send_output =~ "Recipient: claude-123"
    assert send_output =~ "Resolved address: atp://agent/agt_claude_123"
    assert send_output =~ "Message: msg_cli_send"
    assert send_output =~ "Delivery: none yet (polling recipient should run `atp inbox`)"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/messages"
      assert get_req_header(conn, "authorization") == ["Bearer agk_claude_123"]

      assert %{
               "to" => "atp://agent/agt_codex_atp",
               "payload" => %{
                 "messageId" => send_message_id,
                 "role" => "ROLE_USER",
                 "parts" => [%{"text" => "override sender"}]
               }
             } = Jason.decode!(Req.Test.raw_body(conn))

      assert String.starts_with?(send_message_id, "cli-msg-")

      conn
      |> put_status(201)
      |> Req.Test.json(%{
        "message" => %{
          "id" => "msg_override",
          "from" => "atp://agent/agt_claude_123",
          "to" => "atp://agent/agt_codex_atp",
          "created_at" => "2026-05-27T12:01:00Z",
          "payload" => %{
            "messageId" => send_message_id,
            "role" => "ROLE_USER",
            "parts" => [%{"text" => "override sender"}]
          }
        },
        "carrier_status" => "queued",
        "ack_status" => nil,
        "terminal_at" => nil,
        "deliveries" => []
      })
    end)

    override_output =
      capture_io(fn ->
        assert Atp.CLI.run(["send", "codex-atp", "override sender", "--as", "claude-123"]) == 0
      end)

    assert override_output =~ "Sender: claude-123"
    assert override_output =~ "Message: msg_override"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/inbox/claims"
      assert get_req_header(conn, "authorization") == ["Bearer agk_claude_123"]
      assert [claim_key] = get_req_header(conn, "idempotency-key")
      assert String.starts_with?(claim_key, "cli-inbox-")
      assert Jason.decode!(Req.Test.raw_body(conn)) == %{"lease_seconds" => 60}

      conn
      |> put_status(201)
      |> Req.Test.json(%{
        "id" => "dlv_claimed",
        "leased_until" => "2026-05-27T12:05:00Z",
        "message" => %{
          "id" => "msg_claimed",
          "from" => "atp://agent/agt_codex_atp",
          "to" => "atp://agent/agt_claude_123",
          "created_at" => "2026-05-27T12:02:00Z",
          "payload" => %{
            "messageId" => "cli-inbox-message",
            "role" => "ROLE_USER",
            "parts" => [%{"text" => "please review"}]
          }
        }
      })
    end)

    inbox_output = capture_io(fn -> assert Atp.CLI.run(["inbox", "--as", "claude-123"]) == 0 end)

    assert inbox_output =~ "Delivery: dlv_claimed"
    assert inbox_output =~ "Sender: codex-atp (atp://agent/agt_codex_atp)"
    assert inbox_output =~ "Message: msg_claimed"
    assert inbox_output =~ "Timestamp: 2026-05-27T12:02:00Z"
    assert inbox_output =~ "Text: please review"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/deliveries/dlv_claimed/acks"
      assert get_req_header(conn, "authorization") == ["Bearer agk_claude_123"]
      assert [ack_key] = get_req_header(conn, "idempotency-key")
      assert String.starts_with?(ack_key, "cli-ack-")

      assert %{
               "status" => "completed",
               "payload" => %{
                 "messageId" => ack_message_id,
                 "role" => "ROLE_AGENT",
                 "contextId" => context_id,
                 "parts" => [%{"text" => "done reviewing"}]
               }
             } = Jason.decode!(Req.Test.raw_body(conn))

      assert String.starts_with?(ack_message_id, "cli-msg-")
      assert context_id == "ctx_#{ack_message_id}"

      conn
      |> put_status(201)
      |> Req.Test.json(%{
        "ack" => %{
          "id" => "ack_completed",
          "delivery_id" => "dlv_claimed",
          "message_id" => "msg_claimed",
          "status" => "completed"
        },
        "message_status" => %{
          "message" => %{"id" => "msg_claimed"},
          "ack_status" => "completed",
          "carrier_status" => "delivered"
        }
      })
    end)

    ack_output =
      capture_io(fn ->
        assert Atp.CLI.run([
                 "ack",
                 "dlv_claimed",
                 "--completed",
                 "done reviewing",
                 "--as",
                 "claude-123"
               ]) == 0
      end)

    assert ack_output =~ "ACK completed."
    assert ack_output =~ "Delivery: dlv_claimed"
    assert ack_output =~ "Message: msg_claimed"
    assert ack_output =~ "ACK: ack_completed"
  end

  test "send accepts a raw ATP address recipient", %{atp_home: atp_home} do
    seed_initialized_state!(atp_home)
    seed_agent!(atp_home, "codex-atp")
    seed_active_alias!(atp_home, "codex-atp")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/messages"
      assert get_req_header(conn, "authorization") == ["Bearer agk_codex_atp"]

      assert %{
               "to" => "atp://agent/agt_external",
               "payload" => %{
                 "messageId" => send_message_id,
                 "role" => "ROLE_USER",
                 "parts" => [%{"text" => "hello raw"}]
               }
             } = Jason.decode!(Req.Test.raw_body(conn))

      assert String.starts_with?(send_message_id, "cli-msg-")

      conn
      |> put_status(201)
      |> Req.Test.json(%{
        "message" => %{
          "id" => "msg_raw",
          "from" => "atp://agent/agt_codex_atp",
          "to" => "atp://agent/agt_external",
          "created_at" => "2026-05-27T12:03:00Z",
          "payload" => %{
            "messageId" => send_message_id,
            "role" => "ROLE_USER",
            "parts" => [%{"text" => "hello raw"}]
          }
        },
        "carrier_status" => "queued",
        "ack_status" => nil,
        "terminal_at" => nil,
        "deliveries" => []
      })
    end)

    output =
      capture_io(fn ->
        assert Atp.CLI.run(["send", "atp://agent/agt_external", "hello raw"]) == 0
      end)

    assert output =~ "Recipient: atp://agent/agt_external"
    assert output =~ "Recipient address: atp://agent/agt_external"
    assert output =~ "Message: msg_raw"
    assert output =~ "Delivery: none yet (polling recipient should run `atp inbox`)"
  end

  test "message status uses the active alias and renders delivery attempts safely", %{
    atp_home: atp_home
  } do
    seed_initialized_state!(atp_home)
    seed_agent!(atp_home, "codex-atp")
    seed_agent!(atp_home, "claude-123")
    seed_active_alias!(atp_home, "codex-atp")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/messages/msg_cli_status"
      assert get_req_header(conn, "authorization") == ["Bearer agk_codex_atp"]

      Req.Test.json(conn, %{
        "message" => %{
          "id" => "msg_cli_status",
          "from" => "atp://agent/agt_codex_atp",
          "to" => "atp://agent/agt_claude_123",
          "created_at" => "2026-05-27T12:10:00Z",
          "payload" => %{
            "messageId" => "a2a-msg-cli-status",
            "role" => "ROLE_USER",
            "parts" => [
              %{"text" => "raw payload text containing whsec_payload_secret and sig_body"}
            ]
          }
        },
        "carrier_status" => "delivered",
        "ack_status" => "completed",
        "terminal_at" => "2026-05-27T12:12:00Z",
        "deliveries" => [
          %{
            "id" => "dlv_polling_status",
            "mode" => "polling",
            "status" => "leased",
            "claimed_at" => "2026-05-27T12:10:10Z",
            "leased_until" => "2026-05-27T12:11:10Z",
            "attempt_count" => 0,
            "max_attempts" => nil,
            "next_attempt_at" => nil,
            "delivered_at" => nil,
            "last_error" => nil,
            "attempts" => []
          },
          %{
            "id" => "dlv_webhook_status",
            "mode" => "webhook",
            "status" => "retry_scheduled",
            "claimed_at" => nil,
            "leased_until" => nil,
            "attempt_count" => 1,
            "max_attempts" => 3,
            "next_attempt_at" => "2026-05-27T12:15:00Z",
            "delivered_at" => nil,
            "last_error" => "transport_error",
            "webhook_secret" => "whsec_delivery_secret",
            "attempts" => [
              %{
                "id" => "wha_status_1",
                "attempt_number" => 1,
                "result" => "retry_scheduled",
                "response_status" => 503,
                "error" => "timeout",
                "next_attempt_at" => "2026-05-27T12:15:00Z",
                "created_at" => "2026-05-27T12:10:30Z",
                "request_url" => "https://recipient.example.test/hook?secret=whsec_attempt_url",
                "signature" => "sig_attempt_header",
                "raw_body" => "raw body containing whsec_attempt_body"
              }
            ]
          }
        ]
      })
    end)

    output =
      capture_io(fn ->
        assert Atp.CLI.run(["message", "status", "msg_cli_status"]) == 0
      end)

    assert output =~ "Message status."
    assert output =~ "Message: msg_cli_status"
    assert output =~ "Sender: codex-atp (atp://agent/agt_codex_atp)"
    assert output =~ "Recipient: claude-123 (atp://agent/agt_claude_123)"
    assert output =~ "Created: 2026-05-27T12:10:00Z"
    assert output =~ "Carrier status: delivered"
    assert output =~ "ACK status: completed"
    assert output =~ "Terminal: 2026-05-27T12:12:00Z"
    assert output =~ "Delivery: dlv_polling_status"
    assert output =~ "Mode: polling"
    assert output =~ "Attempt count: 0"
    assert output =~ "Claimed: 2026-05-27T12:10:10Z"
    assert output =~ "Lease until: 2026-05-27T12:11:10Z"
    assert output =~ "Delivery: dlv_webhook_status"
    assert output =~ "Mode: webhook"
    assert output =~ "Attempt count: 1/3"
    assert output =~ "Next retry: 2026-05-27T12:15:00Z"
    assert output =~ "Last error: transport_error"
    assert output =~ "Attempt #1: retry_scheduled"
    assert output =~ "Response: 503"
    assert output =~ "Error: timeout"
    assert output =~ "Retry: 2026-05-27T12:15:00Z"
    assert output =~ "Created: 2026-05-27T12:10:30Z"

    refute output =~ "raw payload text"
    refute output =~ "whsec_"
    refute output =~ "sig_"
    refute output =~ "raw body"
    refute output =~ "recipient.example.test"
  end

  test "message status accepts an explicit agent identity override", %{atp_home: atp_home} do
    seed_initialized_state!(atp_home)
    seed_agent!(atp_home, "codex-atp")
    seed_agent!(atp_home, "claude-123")
    seed_active_alias!(atp_home, "codex-atp")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/messages/msg_override_status"
      assert get_req_header(conn, "authorization") == ["Bearer agk_claude_123"]

      Req.Test.json(conn, %{
        "message" => %{
          "id" => "msg_override_status",
          "from" => "atp://agent/agt_claude_123",
          "to" => "atp://agent/agt_codex_atp",
          "created_at" => "2026-05-27T12:20:00Z"
        },
        "carrier_status" => "queued",
        "ack_status" => nil,
        "terminal_at" => nil,
        "deliveries" => []
      })
    end)

    output =
      capture_io(fn ->
        assert Atp.CLI.run([
                 "message",
                 "status",
                 "msg_override_status",
                 "--as",
                 "claude-123"
               ]) == 0
      end)

    assert output =~ "Message: msg_override_status"
    assert output =~ "Sender: claude-123 (atp://agent/agt_claude_123)"
    assert output =~ "Recipient: codex-atp (atp://agent/agt_codex_atp)"
    assert output =~ "ACK status: -"
    assert output =~ "Deliveries: none"
  end

  test "message status reports missing messages as server not found errors", %{
    atp_home: atp_home
  } do
    seed_initialized_state!(atp_home)
    seed_agent!(atp_home, "codex-atp")
    seed_active_alias!(atp_home, "codex-atp")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/messages/msg_missing"
      assert get_req_header(conn, "authorization") == ["Bearer agk_codex_atp"]

      conn
      |> put_status(404)
      |> Req.Test.json(%{
        "error" => %{
          "code" => "not_found",
          "message" => "The requested resource could not be found."
        }
      })
    end)

    stderr =
      capture_io(:stderr, fn ->
        assert Atp.CLI.run(["message", "status", "msg_missing"]) == 1
      end)

    assert stderr =~ "server returned 404 not_found: The requested resource could not be found."
  end

  test "session commands open, accept, reject, and send using local aliases", %{
    atp_home: atp_home
  } do
    seed_initialized_state!(atp_home)
    seed_agent!(atp_home, "codex-atp")
    seed_agent!(atp_home, "claude-123")
    seed_active_alias!(atp_home, "codex-atp")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/sessions"
      assert get_req_header(conn, "authorization") == ["Bearer agk_codex_atp"]
      assert [open_key] = get_req_header(conn, "idempotency-key")
      assert String.starts_with?(open_key, "cli-session-open-")

      assert %{
               "to" => "atp://agent/agt_claude_123",
               "payload" => %{
                 "messageId" => opening_message_id,
                 "role" => "ROLE_USER",
                 "parts" => [%{"text" => "let's review"}]
               }
             } = Jason.decode!(Req.Test.raw_body(conn))

      assert String.starts_with?(opening_message_id, "cli-msg-")

      conn
      |> put_status(201)
      |> Req.Test.json(%{
        "session" => %{
          "id" => "ses_cli",
          "status" => "pending",
          "initiator" => "atp://agent/agt_codex_atp",
          "recipient" => "atp://agent/agt_claude_123",
          "opening_message_id" => "msg_opening",
          "last_sequence" => 1
        },
        "message_status" => %{
          "message" => %{
            "id" => "msg_opening",
            "from" => "atp://agent/agt_codex_atp",
            "to" => "atp://agent/agt_claude_123",
            "session_id" => "ses_cli",
            "session_sequence" => 1,
            "payload" => %{
              "messageId" => opening_message_id,
              "role" => "ROLE_USER",
              "parts" => [%{"text" => "let's review"}]
            }
          },
          "carrier_status" => "queued",
          "ack_status" => nil,
          "deliveries" => [%{"id" => "dlv_opening", "status" => "leased"}]
        }
      })
    end)

    open_output =
      capture_io(fn ->
        assert Atp.CLI.run(["session", "open", "claude-123", "let's review"]) == 0
      end)

    assert open_output =~ "Session opened."
    assert open_output =~ "Sender: codex-atp"
    assert open_output =~ "Recipient: claude-123"
    assert open_output =~ "Resolved address: atp://agent/agt_claude_123"
    assert open_output =~ "Session: ses_cli"
    assert open_output =~ "Status: pending"
    assert open_output =~ "Opening message: msg_opening"
    assert open_output =~ "Opening delivery: dlv_opening"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/sessions/ses_cli/accept"
      assert get_req_header(conn, "authorization") == ["Bearer agk_claude_123"]
      assert get_req_header(conn, "idempotency-key") == ["cli-session-accept-ses_cli"]
      assert Jason.decode!(Req.Test.raw_body(conn)) == %{}

      conn
      |> put_status(201)
      |> Req.Test.json(%{
        "session" => %{"id" => "ses_cli", "status" => "open"},
        "ack" => %{
          "id" => "ack_accept",
          "delivery_id" => "dlv_opening",
          "message_id" => "msg_opening",
          "status" => "accepted"
        },
        "message_status" => %{
          "message" => %{"id" => "msg_opening"},
          "ack_status" => "accepted"
        }
      })
    end)

    accept_output =
      capture_io(fn ->
        assert Atp.CLI.run(["session", "accept", "ses_cli", "--as", "claude-123"]) == 0
      end)

    assert accept_output =~ "Session accepted."
    assert accept_output =~ "Session: ses_cli"
    assert accept_output =~ "Status: open"
    assert accept_output =~ "Opening delivery: dlv_opening"
    assert accept_output =~ "ACK: ack_accept"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/sessions/ses_cli/messages"
      assert get_req_header(conn, "authorization") == ["Bearer agk_claude_123"]
      assert [send_key] = get_req_header(conn, "idempotency-key")
      assert String.starts_with?(send_key, "cli-session-send-")

      assert %{
               "payload" => %{
                 "messageId" => session_message_id,
                 "role" => "ROLE_USER",
                 "parts" => [%{"text" => "I see the tradeoff"}]
               }
             } = Jason.decode!(Req.Test.raw_body(conn))

      assert String.starts_with?(session_message_id, "cli-msg-")

      conn
      |> put_status(201)
      |> Req.Test.json(%{
        "session" => %{"id" => "ses_cli", "status" => "open", "last_sequence" => 2},
        "message_status" => %{
          "message" => %{
            "id" => "msg_session_reply",
            "session_id" => "ses_cli",
            "session_sequence" => 2
          },
          "deliveries" => [%{"id" => "dlv_session_reply", "status" => "leased"}]
        }
      })
    end)

    send_output =
      capture_io(fn ->
        assert Atp.CLI.run([
                 "session",
                 "send",
                 "ses_cli",
                 "I see the tradeoff",
                 "--as",
                 "claude-123"
               ]) == 0
      end)

    assert send_output =~ "Session message sent."
    assert send_output =~ "Session: ses_cli"
    assert send_output =~ "Sequence: 2"
    assert send_output =~ "Message: msg_session_reply"
    assert send_output =~ "Delivery: dlv_session_reply"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/sessions/ses_reject/reject"
      assert get_req_header(conn, "authorization") == ["Bearer agk_claude_123"]
      assert get_req_header(conn, "idempotency-key") == ["cli-session-reject-ses_reject"]

      assert %{
               "payload" => %{
                 "messageId" => reject_message_id,
                 "role" => "ROLE_AGENT",
                 "contextId" => reject_context_id,
                 "parts" => [%{"text" => "not this time"}]
               }
             } = Jason.decode!(Req.Test.raw_body(conn))

      assert reject_message_id == "cli-msg-session-reject-ses_reject"
      assert reject_context_id == "ctx_#{reject_message_id}"

      conn
      |> put_status(201)
      |> Req.Test.json(%{
        "session" => %{"id" => "ses_reject", "status" => "rejected"},
        "ack" => %{
          "id" => "ack_reject",
          "delivery_id" => "dlv_reject",
          "message_id" => "msg_reject",
          "status" => "rejected"
        },
        "message_status" => %{
          "message" => %{"id" => "msg_reject"},
          "ack_status" => "rejected"
        }
      })
    end)

    reject_output =
      capture_io(fn ->
        assert Atp.CLI.run([
                 "session",
                 "reject",
                 "ses_reject",
                 "not this time",
                 "--as",
                 "claude-123"
               ]) == 0
      end)

    assert reject_output =~ "Session rejected."
    assert reject_output =~ "Session: ses_reject"
    assert reject_output =~ "Status: rejected"
    assert reject_output =~ "Opening delivery: dlv_reject"
    assert reject_output =~ "ACK: ack_reject"
  end

  test "session show and watch print ordered transcript rows", %{atp_home: atp_home} do
    seed_initialized_state!(atp_home)
    seed_agent!(atp_home, "codex-atp")
    seed_agent!(atp_home, "claude-123")
    seed_active_alias!(atp_home, "codex-atp")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/sessions/ses_cli"
      assert get_req_header(conn, "authorization") == ["Bearer agk_codex_atp"]

      Req.Test.json(conn, session_transcript_response([session_message(1, "msg_opening")]))
    end)

    show_output =
      capture_io(fn ->
        assert Atp.CLI.run(["session", "show", "ses_cli"]) == 0
      end)

    assert show_output =~ "Session: ses_cli"
    assert show_output =~ "Status: open"
    assert show_output =~ "Initiator: codex-atp (atp://agent/agt_codex_atp)"
    assert show_output =~ "Recipient: claude-123 (atp://agent/agt_claude_123)"

    assert show_output =~
             "Seq  Time                  Sender      Recipient   Status    Message"

    assert show_output =~
             "1    2026-05-27T12:00:00Z  codex-atp   claude-123  accepted  opening turn"

    Application.put_env(:atp, Atp.CLI,
      req_options: [plug: {Req.Test, __MODULE__}],
      watch_poll_interval_ms: 0,
      watch_max_polls: 2
    )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/sessions/ses_cli"
      assert get_req_header(conn, "authorization") == ["Bearer agk_codex_atp"]

      Req.Test.json(conn, session_transcript_response([session_message(1, "msg_opening")]))
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/sessions/ses_cli"
      assert get_req_header(conn, "authorization") == ["Bearer agk_codex_atp"]

      Req.Test.json(
        conn,
        session_transcript_response([
          session_message(1, "msg_opening"),
          session_message(
            2,
            "msg_reply",
            "atp://agent/agt_claude_123",
            "atp://agent/agt_codex_atp",
            "2026-05-27T12:01:00Z",
            nil,
            "reply turn with a longer message that should wrap onto a continuation row while keeping sender recipient status and message columns aligned in the terminal"
          )
        ])
      )
    end)

    watch_output =
      capture_io(fn ->
        assert Atp.CLI.run(["session", "watch", "ses_cli"]) == 0
      end)

    assert watch_output =~
             "Seq  Time                  Sender      Recipient   Status    Message"

    assert watch_output =~
             "1    2026-05-27T12:00:00Z  codex-atp   claude-123  accepted  opening turn"

    assert watch_output =~
             "2    2026-05-27T12:01:00Z  claude-123  codex-atp   queued    reply turn with a longer message that should wrap onto a continuation row while keeping sender recipient status and"

    assert watch_output =~
             "                                                             message columns aligned in the terminal"

    assert [_header] = Regex.scan(~r/Seq  Time/, watch_output)
    assert [] = Regex.scan(~r/msg_opening/, watch_output)
  end

  test "session show and watch accept explicit agent identity overrides", %{atp_home: atp_home} do
    seed_initialized_state!(atp_home)
    seed_agent!(atp_home, "codex-atp")
    seed_agent!(atp_home, "claude-123")
    seed_active_alias!(atp_home, "codex-atp")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/sessions/ses_cli"
      assert get_req_header(conn, "authorization") == ["Bearer agk_claude_123"]

      Req.Test.json(conn, session_transcript_response([session_message(1, "msg_opening")]))
    end)

    show_output =
      capture_io(fn ->
        assert Atp.CLI.run(["session", "show", "ses_cli", "--as", "claude-123"]) == 0
      end)

    assert show_output =~ "Session: ses_cli"

    assert show_output =~
             "1    2026-05-27T12:00:00Z  codex-atp   claude-123  accepted  opening turn"

    Application.put_env(:atp, Atp.CLI,
      req_options: [plug: {Req.Test, __MODULE__}],
      watch_poll_interval_ms: 0,
      watch_max_polls: 1
    )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/sessions/ses_cli"
      assert get_req_header(conn, "authorization") == ["Bearer agk_claude_123"]

      Req.Test.json(conn, session_transcript_response([session_message(1, "msg_opening")]))
    end)

    watch_output =
      capture_io(fn ->
        assert Atp.CLI.run(["session", "watch", "ses_cli", "--as", "claude-123"]) == 0
      end)

    assert watch_output =~
             "Seq  Time                  Sender      Recipient   Status    Message"

    assert watch_output =~
             "1    2026-05-27T12:00:00Z  codex-atp   claude-123  accepted  opening turn"
  end

  defp seed_initialized_state!(atp_home) do
    File.mkdir_p!(atp_home)

    File.write!(Path.join(atp_home, "config.toml"), """
    server_url = "http://localhost:4000"
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

  defp seed_active_alias!(atp_home, alias) do
    config_path = Path.join(atp_home, "config.toml")

    config_path
    |> File.read!()
    |> String.replace(~r/^active_alias = ".*"$/m, ~s(active_alias = "#{alias}"))
    |> then(&File.write!(config_path, &1))
  end

  defp owner_only?(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o077) == 0
  end

  defp session_transcript_response(messages) do
    %{
      "session" => %{
        "id" => "ses_cli",
        "status" => "open",
        "initiator" => "atp://agent/agt_codex_atp",
        "recipient" => "atp://agent/agt_claude_123",
        "opening_message_id" => "msg_opening",
        "last_sequence" => length(messages),
        "created_at" => "2026-05-27T12:00:00Z",
        "opened_at" => "2026-05-27T12:00:30Z",
        "terminal_at" => nil
      },
      "messages" => messages
    }
  end

  defp session_message(1, message_id) do
    session_message(
      1,
      message_id,
      "atp://agent/agt_codex_atp",
      "atp://agent/agt_claude_123",
      "2026-05-27T12:00:00Z",
      "accepted",
      "opening turn"
    )
  end

  defp session_message(2, message_id) do
    session_message(
      2,
      message_id,
      "atp://agent/agt_claude_123",
      "atp://agent/agt_codex_atp",
      "2026-05-27T12:01:00Z",
      nil,
      "reply turn"
    )
  end

  defp session_message(sequence, message_id, from, to, created_at, ack_status, text) do
    %{
      "message" => %{
        "id" => message_id,
        "from" => from,
        "to" => to,
        "session_id" => "ses_cli",
        "session_sequence" => sequence,
        "created_at" => created_at,
        "payload" => %{
          "messageId" => "a2a-#{message_id}",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => text}]
        }
      },
      "carrier_status" => "queued",
      "ack_status" => ack_status
    }
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(nil), do: Application.delete_env(:atp, Atp.CLI)
  defp restore_app_env(value), do: Application.put_env(:atp, Atp.CLI, value)
end
