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

    seed_active_alias!(atp_home, "claude-123")

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

    inbox_output = capture_io(fn -> assert Atp.CLI.run(["inbox"]) == 0 end)

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
        assert Atp.CLI.run(["ack", "dlv_claimed", "--completed", "done reviewing"]) == 0
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

    seed_active_alias!(atp_home, "claude-123")

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
        assert Atp.CLI.run(["session", "accept", "ses_cli"]) == 0
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
        assert Atp.CLI.run(["session", "send", "ses_cli", "I see the tradeoff"]) == 0
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
        assert Atp.CLI.run(["session", "reject", "ses_reject", "not this time"]) == 0
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
    assert show_output =~ "Seq\tTime\tSender\tRecipient\tStatus\tMessage"
    assert show_output =~ "1\t2026-05-27T12:00:00Z\tcodex-atp\tclaude-123\taccepted\topening turn"

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
          session_message(2, "msg_reply")
        ])
      )
    end)

    watch_output =
      capture_io(fn ->
        assert Atp.CLI.run(["session", "watch", "ses_cli"]) == 0
      end)

    assert watch_output =~ "Seq\tTime\tSender\tRecipient\tStatus\tMessage"

    assert watch_output =~
             "1\t2026-05-27T12:00:00Z\tcodex-atp\tclaude-123\taccepted\topening turn"

    assert watch_output =~ "2\t2026-05-27T12:01:00Z\tclaude-123\tcodex-atp\tqueued\treply turn"

    assert [_header] = Regex.scan(~r/Seq\tTime\tSender\tRecipient\tStatus\tMessage/, watch_output)
    assert [] = Regex.scan(~r/msg_opening/, watch_output)
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
