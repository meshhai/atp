defmodule Atp.DurableLedgerTest do
  use ExUnit.Case, async: false

  alias Atp.Identity.Agent
  alias Atp.Transport
  alias Atp.Transport.{Delivery, DeliveryClaim, Message}
  alias Atp.Transport.DurableLedger
  alias Atp.Transport.WebhookDelivery.AttemptResult

  defmodule RecordingLedger do
    @behaviour DurableLedger

    @impl DurableLedger
    def accept_direct_message(sender, params, idempotency_key, route) do
      send(Map.fetch!(params, :test_pid), {
        :accept_direct_message,
        sender,
        Map.delete(params, :test_pid),
        idempotency_key,
        route
      })

      {:ok, 201, %{"id" => "msg_configured"}, nil}
    end

    @impl DurableLedger
    def open_session(initiator, params, idempotency_key, route) do
      send(Map.fetch!(params, :test_pid), {
        :open_session,
        initiator,
        Map.delete(params, :test_pid),
        idempotency_key,
        route
      })

      {:ok, 201, %{"session" => %{"id" => "ses_configured"}}, nil}
    end

    @impl DurableLedger
    def preflight_session_message(sender, session_id, params, idempotency_key, route) do
      send(Map.fetch!(params, :test_pid), {
        :preflight_session_message,
        sender,
        session_id,
        Map.delete(params, :test_pid),
        idempotency_key,
        route
      })

      :ok
    end

    @impl DurableLedger
    def send_session_message(sender, session_id, params, idempotency_key, route) do
      send(Map.fetch!(params, :test_pid), {
        :send_session_message,
        sender,
        session_id,
        Map.delete(params, :test_pid),
        idempotency_key,
        route
      })

      {:ok, 201, %{"message_status" => %{"message" => %{"id" => "msg_configured"}}}, nil}
    end

    @impl DurableLedger
    def accept_session(recipient, session_id, params, idempotency_key, route) do
      send(Map.fetch!(params, :test_pid), {
        :accept_session,
        recipient,
        session_id,
        Map.delete(params, :test_pid),
        idempotency_key,
        route
      })

      {:ok, 201, %{"ack" => %{"status" => "accepted"}, "session" => %{"id" => session_id}}}
    end

    @impl DurableLedger
    def reject_session(recipient, session_id, params, idempotency_key, route) do
      send(Map.fetch!(params, :test_pid), {
        :reject_session,
        recipient,
        session_id,
        Map.delete(params, :test_pid),
        idempotency_key,
        route
      })

      {:ok, 201, %{"ack" => %{"status" => "rejected"}, "session" => %{"id" => session_id}}}
    end

    @impl DurableLedger
    def ack_delivery(recipient, delivery_id, params, idempotency_key, route) do
      send(Map.fetch!(params, :test_pid), {
        :ack_delivery,
        recipient,
        delivery_id,
        Map.delete(params, :test_pid),
        idempotency_key,
        route
      })

      {:ok, 201, %{"ack" => %{"status" => Map.fetch!(params, "status")}}}
    end

    @impl DurableLedger
    def claim_due_webhook_delivery(opts) do
      notify_test_pid(opts, {:claim_due_webhook_delivery, opts})
      {:ok, nil}
    end

    @impl DurableLedger
    def claim_webhook_delivery(delivery_id, opts) do
      notify_test_pid(opts, {:claim_webhook_delivery, delivery_id, opts})
      {:error, :not_found}
    end

    @impl DurableLedger
    def finish_claimed_webhook_delivery(claim, result, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:finish_claimed_webhook_delivery, claim, result, opts}
      )

      {:error, :stale_delivery_claim}
    end

    @impl DurableLedger
    def terminalize_claimed_webhook_delivery(claim, reason, opts) do
      send(Keyword.fetch!(opts, :test_pid), {
        :terminalize_claimed_webhook_delivery,
        claim,
        reason,
        opts
      })

      {:error, :stale_delivery_claim}
    end

    defp notify_test_pid(opts, message) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, test_pid} -> send(test_pid, message)
        :error -> :ok
      end
    end
  end

  setup do
    original_config = Application.get_env(:atp, DurableLedger)

    on_exit(fn ->
      case original_config do
        nil -> Application.delete_env(:atp, DurableLedger)
        config -> Application.put_env(:atp, DurableLedger, config)
      end
    end)

    :ok
  end

  test "default durable ledger adapter is the Postgres implementation" do
    assert DurableLedger.adapter() == Atp.Transport.DurableLedger.Postgres
  end

  test "durable ledger delegates direct message intake to configured adapter" do
    Application.put_env(:atp, DurableLedger, adapter: RecordingLedger)

    sender = %Agent{
      id: "agt_configured_sender",
      account_id: "acc_configured",
      address: "atp://agent/agt_configured_sender",
      status: "active"
    }

    params = %{
      "to" => "atp://agent/agt_configured_recipient",
      "payload" => %{
        "messageId" => "msg_configured",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "hello"}]
      },
      test_pid: self()
    }

    assert {:ok, 201, %{"id" => "msg_configured"}, nil} =
             DurableLedger.accept_direct_message(
               sender,
               params,
               "direct-message-key",
               "POST /api/messages"
             )

    assert_received {
      :accept_direct_message,
      ^sender,
      %{
        "to" => "atp://agent/agt_configured_recipient",
        "payload" => %{
          "messageId" => "msg_configured",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => "hello"}]
        }
      },
      "direct-message-key",
      "POST /api/messages"
    }
  end

  test "transport facade delegates direct message intake to the durable ledger" do
    Application.put_env(:atp, DurableLedger, adapter: RecordingLedger)

    sender = %Agent{
      id: "agt_transport_sender",
      account_id: "acc_transport",
      address: "atp://agent/agt_transport_sender",
      status: "active"
    }

    params = %{
      "to" => "atp://agent/agt_transport_recipient",
      "payload" => %{
        "messageId" => "msg_transport",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "hello"}]
      },
      test_pid: self()
    }

    assert {:ok, 201, %{"id" => "msg_configured"}} =
             Transport.send_message(sender, params, nil, "POST /api/messages")

    assert_received {
      :accept_direct_message,
      ^sender,
      %{
        "to" => "atp://agent/agt_transport_recipient",
        "payload" => %{
          "messageId" => "msg_transport",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => "hello"}]
        }
      },
      nil,
      "POST /api/messages"
    }
  end

  test "transport facade delegates session opening to the durable ledger through runtime" do
    Application.put_env(:atp, DurableLedger, adapter: RecordingLedger)

    sender = %Agent{
      id: "agt_transport_session_sender",
      account_id: "acc_transport_session",
      address: "atp://agent/agt_transport_session_sender",
      status: "active"
    }

    params = %{
      "to" => "atp://agent/agt_transport_session_recipient",
      "payload" => %{
        "messageId" => "msg_transport_session_open",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "open"}]
      },
      test_pid: self()
    }

    assert {:ok, 201, %{"session" => %{"id" => "ses_configured"}}} =
             Transport.open_session(
               sender,
               params,
               "transport-session-open-key",
               "POST /api/sessions"
             )

    assert_received {
      :open_session,
      ^sender,
      %{
        "to" => "atp://agent/agt_transport_session_recipient",
        "payload" => %{
          "messageId" => "msg_transport_session_open",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => "open"}]
        }
      },
      "transport-session-open-key",
      "POST /api/sessions"
    }
  end

  test "durable ledger delegates session intake to configured adapter" do
    Application.put_env(:atp, DurableLedger, adapter: RecordingLedger)

    sender = %Agent{
      id: "agt_session_sender",
      account_id: "acc_session",
      address: "atp://agent/agt_session_sender",
      status: "active"
    }

    open_params = %{
      "to" => "atp://agent/agt_session_recipient",
      "payload" => %{
        "messageId" => "msg_session_open",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "open"}]
      },
      test_pid: self()
    }

    assert {:ok, 201, %{"session" => %{"id" => "ses_configured"}}, nil} =
             DurableLedger.open_session(
               sender,
               open_params,
               "session-open-key",
               "POST /api/sessions"
             )

    assert_received {
      :open_session,
      ^sender,
      %{
        "to" => "atp://agent/agt_session_recipient",
        "payload" => %{
          "messageId" => "msg_session_open",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => "open"}]
        }
      },
      "session-open-key",
      "POST /api/sessions"
    }

    message_params = %{
      "payload" => %{
        "messageId" => "msg_session_send",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "send"}]
      },
      test_pid: self()
    }

    assert {:ok, 201, %{"message_status" => %{"message" => %{"id" => "msg_configured"}}}, nil} =
             DurableLedger.send_session_message(
               sender,
               "ses_configured",
               message_params,
               "session-send-key",
               "POST /api/sessions/ses_configured/messages"
             )

    assert_received {
      :send_session_message,
      ^sender,
      "ses_configured",
      %{
        "payload" => %{
          "messageId" => "msg_session_send",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => "send"}]
        }
      },
      "session-send-key",
      "POST /api/sessions/ses_configured/messages"
    }

    preflight_params = %{
      "payload" => %{
        "messageId" => "msg_session_preflight",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "preflight"}]
      },
      test_pid: self()
    }

    assert :ok =
             DurableLedger.preflight_session_message(
               sender,
               "ses_configured",
               preflight_params,
               "session-preflight-key",
               "POST /api/sessions/ses_configured/messages"
             )

    assert_received {
      :preflight_session_message,
      ^sender,
      "ses_configured",
      %{
        "payload" => %{
          "messageId" => "msg_session_preflight",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => "preflight"}]
        }
      },
      "session-preflight-key",
      "POST /api/sessions/ses_configured/messages"
    }
  end

  test "durable ledger delegates session lifecycle to configured adapter" do
    Application.put_env(:atp, DurableLedger, adapter: RecordingLedger)

    recipient = %Agent{
      id: "agt_session_lifecycle_recipient",
      account_id: "acc_session_lifecycle",
      address: "atp://agent/agt_session_lifecycle_recipient",
      status: "active"
    }

    accept_params = %{
      "payload" => %{
        "messageId" => "msg_session_accept",
        "role" => "ROLE_AGENT",
        "parts" => [%{"text" => "accepted"}]
      },
      test_pid: self()
    }

    assert {:ok, 201, %{"ack" => %{"status" => "accepted"}, "session" => %{"id" => "ses_accept"}}} =
             DurableLedger.accept_session(
               recipient,
               "ses_accept",
               accept_params,
               "session-accept-key",
               "POST /api/sessions/ses_accept/accept"
             )

    assert_received {
      :accept_session,
      ^recipient,
      "ses_accept",
      %{
        "payload" => %{
          "messageId" => "msg_session_accept",
          "role" => "ROLE_AGENT",
          "parts" => [%{"text" => "accepted"}]
        }
      },
      "session-accept-key",
      "POST /api/sessions/ses_accept/accept"
    }

    reject_params = %{
      "payload" => %{
        "messageId" => "msg_session_reject",
        "role" => "ROLE_AGENT",
        "parts" => [%{"text" => "rejected"}]
      },
      test_pid: self()
    }

    assert {:ok, 201, %{"ack" => %{"status" => "rejected"}, "session" => %{"id" => "ses_reject"}}} =
             DurableLedger.reject_session(
               recipient,
               "ses_reject",
               reject_params,
               "session-reject-key",
               "POST /api/sessions/ses_reject/reject"
             )

    assert_received {
      :reject_session,
      ^recipient,
      "ses_reject",
      %{
        "payload" => %{
          "messageId" => "msg_session_reject",
          "role" => "ROLE_AGENT",
          "parts" => [%{"text" => "rejected"}]
        }
      },
      "session-reject-key",
      "POST /api/sessions/ses_reject/reject"
    }
  end

  test "durable ledger delegates delivery ACK to configured adapter" do
    Application.put_env(:atp, DurableLedger, adapter: RecordingLedger)

    recipient = %Agent{
      id: "agt_ack_recipient",
      account_id: "acc_ack",
      address: "atp://agent/agt_ack_recipient",
      status: "active"
    }

    params = %{
      "status" => "completed",
      "payload" => %{
        "messageId" => "msg_ack",
        "role" => "ROLE_AGENT",
        "parts" => [%{"text" => "done"}]
      },
      test_pid: self()
    }

    assert {:ok, 201, %{"ack" => %{"status" => "completed"}}} =
             DurableLedger.ack_delivery(
               recipient,
               "dlv_ack",
               params,
               "ack-key",
               "POST /api/deliveries/dlv_ack/ack"
             )

    assert_received {
      :ack_delivery,
      ^recipient,
      "dlv_ack",
      %{
        "status" => "completed",
        "payload" => %{
          "messageId" => "msg_ack",
          "role" => "ROLE_AGENT",
          "parts" => [%{"text" => "done"}]
        }
      },
      "ack-key",
      "POST /api/deliveries/dlv_ack/ack"
    }
  end

  test "durable ledger delegates delivery claim operations to configured adapter" do
    Application.put_env(:atp, DurableLedger, adapter: RecordingLedger)

    assert {:ok, nil} = DurableLedger.claim_due_webhook_delivery(test_pid: self())
    assert_received {:claim_due_webhook_delivery, opts}
    assert Keyword.fetch!(opts, :test_pid) == self()

    assert {:error, :not_found} =
             DurableLedger.claim_webhook_delivery("dlv_configured", test_pid: self())

    assert_received {:claim_webhook_delivery, "dlv_configured", opts}
    assert Keyword.fetch!(opts, :test_pid) == self()

    assert {:ok, nil} = DurableLedger.claim_due_webhook_delivery()
    assert {:error, :not_found} = DurableLedger.claim_webhook_delivery("dlv_default_opts")

    claim = %DeliveryClaim{
      delivery: %Delivery{id: "dlv_configured"},
      message: %Message{id: "msg_configured"},
      recipient_agent: %Agent{id: "agt_configured"},
      claim_token: "dcl_configured",
      leased_until: DateTime.utc_now(:microsecond),
      attempt_number: 1
    }

    result = %AttemptResult{
      attempt_number: 1,
      response_status: 200,
      error: nil,
      result: "success",
      delivery_status: "delivered",
      message_status: "delivered",
      next_attempt_at: nil,
      delivered_at: DateTime.utc_now(:microsecond)
    }

    assert {:error, :stale_delivery_claim} =
             DurableLedger.finish_claimed_webhook_delivery(claim, result, test_pid: self())

    assert_received {:finish_claimed_webhook_delivery, ^claim, ^result, opts}
    assert Keyword.fetch!(opts, :test_pid) == self()

    assert {:error, :stale_delivery_claim} =
             DurableLedger.terminalize_claimed_webhook_delivery(
               claim,
               :message_acked,
               test_pid: self()
             )

    assert_received {:terminalize_claimed_webhook_delivery, ^claim, :message_acked, opts}
    assert Keyword.fetch!(opts, :test_pid) == self()
  end

  test "durable ledger contract documents carrier guarantees" do
    {:docs_v1, _annotation, :elixir, _format, %{"en" => module_doc}, _metadata, docs} =
      Code.fetch_docs(DurableLedger)

    assert module_doc =~ "atomic"
    assert module_doc =~ "lease ownership"
    assert module_doc =~ "stale-claim rejection"
    assert module_doc =~ "session-order eligibility"
    assert module_doc =~ "storage engine"

    direct_intake_doc = callback_doc(docs, :accept_direct_message, 4)

    assert direct_intake_doc =~ "direct message"
    assert direct_intake_doc =~ "idempotency"
    assert direct_intake_doc =~ "sender policy"
    assert direct_intake_doc =~ "delivery work"
    assert_no_active_webhook_dispatch(direct_intake_doc)
    refute direct_intake_doc =~ ~r/\b(SQL|Ecto|table|row|lock)\b/i

    session_open_doc = callback_doc(docs, :open_session, 4)

    assert session_open_doc =~ "session"
    assert session_open_doc =~ "opening message"
    assert session_open_doc =~ "idempotency"
    assert session_open_doc =~ "delivery work"
    assert_no_active_webhook_dispatch(session_open_doc)
    refute session_open_doc =~ ~r/\b(SQL|Ecto|table|row|lock)\b/i

    session_send_doc = callback_doc(docs, :send_session_message, 5)

    assert session_send_doc =~ "session message"
    assert session_send_doc =~ "idempotency"
    assert session_send_doc =~ "sequence"
    assert session_send_doc =~ "delivery work"
    assert_no_active_webhook_dispatch(session_send_doc)
    refute session_send_doc =~ ~r/\b(SQL|Ecto|table|row|lock)\b/i

    session_preflight_doc = callback_doc(docs, :preflight_session_message, 5)

    assert session_preflight_doc =~ "preflight"
    assert session_preflight_doc =~ "without mutating carrier state"
    assert session_preflight_doc =~ "Final correctness"
    refute session_preflight_doc =~ ~r/\b(SQL|Ecto|table|row|lock)\b/i

    session_accept_doc = callback_doc(docs, :accept_session, 5)

    assert session_accept_doc =~ "recipient"
    assert session_accept_doc =~ "idempotency"
    assert session_accept_doc =~ "ACK"
    assert session_accept_doc =~ "open"
    assert_no_active_webhook_dispatch(session_accept_doc)
    refute session_accept_doc =~ ~r/\b(SQL|Ecto|table|row|lock)\b/i

    session_reject_doc = callback_doc(docs, :reject_session, 5)

    assert session_reject_doc =~ "recipient"
    assert session_reject_doc =~ "idempotency"
    assert session_reject_doc =~ "ACK"
    assert session_reject_doc =~ "terminal"
    assert_no_active_webhook_dispatch(session_reject_doc)
    refute session_reject_doc =~ ~r/\b(SQL|Ecto|table|row|lock)\b/i

    ack_delivery_doc = callback_doc(docs, :ack_delivery, 5)

    assert ack_delivery_doc =~ "recipient-owned delivery ACK"
    assert ack_delivery_doc =~ "idempotency"
    assert ack_delivery_doc =~ "lease"
    assert ack_delivery_doc =~ "delivery validation"
    assert ack_delivery_doc =~ "ACK transition rules"
    assert ack_delivery_doc =~ "durable opening-session state transitions"
    assert_no_active_webhook_dispatch(ack_delivery_doc)
    refute ack_delivery_doc =~ ~r/\b(SQL|Ecto|table|row|lock)\b/i
  end

  defp callback_doc(docs, name, arity) do
    Enum.find_value(docs, fn
      {{:callback, ^name, ^arity}, _line, _signatures, %{"en" => doc}, _metadata} -> doc
      _doc -> nil
    end)
  end

  defp assert_no_active_webhook_dispatch(doc) do
    assert doc =~ "must not perform active"
    assert doc =~ "webhook dispatch"
  end
end
