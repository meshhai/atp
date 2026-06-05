defmodule Atp.Support.DurableLedgerContract.PostgresHarness do
  @moduledoc """
  Postgres/Ecto fixture harness for the durable ledger delivery claim contract.

  The shared contract stays adapter-neutral. This harness owns the current
  Postgres-backed setup, state mutation, and persistence reads needed to
  exercise the Postgres adapter.
  """

  @endpoint AtpWeb.Endpoint

  import Ecto.Query
  import Phoenix.ConnTest

  alias Atp.Identity.Agent
  alias Atp.Repo

  alias Atp.Transport.{
    Ack,
    Delivery,
    Message,
    SenderPolicies,
    SenderPolicy,
    Session,
    WebhookAttempt,
    WebhookDelivery
  }

  @spec prepare_direct_message_pair!(Plug.Conn.t(), String.t()) :: {Agent.t(), Agent.t()}
  def prepare_direct_message_pair!(conn, key) do
    {sender, recipient} = register_agent_pair!(conn, key)

    {get_agent!(sender["id"]), get_agent!(recipient["id"])}
  end

  @spec prepare_session_pair!(Plug.Conn.t(), String.t()) :: {Agent.t(), Agent.t()}
  def prepare_session_pair!(conn, key), do: prepare_direct_message_pair!(conn, key)

  @spec prepare_active_webhook_direct_message_pair!(Plug.Conn.t(), String.t()) ::
          {Agent.t(), Agent.t()}
  def prepare_active_webhook_direct_message_pair!(conn, key) do
    {sender, recipient} = register_agent_pair!(conn, key)

    Atp.ConnCase.configure_webhook!(
      recipient,
      "configure-#{key}-webhook",
      "https://recipient.example.test/atp/#{key}"
    )

    {get_agent!(sender["id"]), get_agent!(recipient["id"])}
  end

  @spec prepare_active_webhook_session_pair!(Plug.Conn.t(), String.t()) ::
          {Agent.t(), Agent.t()}
  def prepare_active_webhook_session_pair!(conn, key),
    do: prepare_active_webhook_direct_message_pair!(conn, key)

  @spec prepare_direct_message_principal_scope!(Plug.Conn.t(), String.t()) ::
          {Agent.t(), Agent.t(), Agent.t()}
  def prepare_direct_message_principal_scope!(conn, key) do
    account = Atp.ConnCase.create_account!(conn)
    promote_to_basic!(account)

    account_token = account["account_api_key"]["token"]
    first_sender = Atp.ConnCase.register_agent!(account_token, "register-#{key}-first", %{})
    second_sender = Atp.ConnCase.register_agent!(account_token, "register-#{key}-second", %{})
    recipient = Atp.ConnCase.register_agent!(account_token, "register-#{key}-recipient", %{})

    {get_agent!(first_sender["id"]), get_agent!(second_sender["id"]), get_agent!(recipient["id"])}
  end

  @spec carrier_counts() :: %{messages: non_neg_integer(), deliveries: non_neg_integer()}
  def carrier_counts do
    %{
      messages: Repo.aggregate(Message, :count, :id),
      deliveries: Repo.aggregate(Delivery, :count, :id)
    }
  end

  @spec session_carrier_counts() :: %{
          messages: non_neg_integer(),
          deliveries: non_neg_integer(),
          sessions: non_neg_integer()
        }
  def session_carrier_counts do
    carrier_counts()
    |> Map.put(:sessions, Repo.aggregate(Session, :count, :id))
  end

  @spec sender_policy_count() :: non_neg_integer()
  def sender_policy_count, do: Repo.aggregate(SenderPolicy, :count, :id)

  @spec prepare_due_webhook_delivery!(Plug.Conn.t(), String.t()) ::
          {Delivery.t(), Message.t(), Agent.t()}
  def prepare_due_webhook_delivery!(conn, key) do
    {delivery, message, recipient_agent, _recipient} =
      prepare_due_webhook_delivery_context!(conn, key)

    {delivery, message, recipient_agent}
  end

  @spec prepare_due_webhook_delivery_context!(Plug.Conn.t(), String.t()) ::
          {Delivery.t(), Message.t(), Agent.t(), map()}
  def prepare_due_webhook_delivery_context!(conn, key) do
    {sender, recipient} = register_agent_pair!(conn, key)

    Atp.ConnCase.configure_webhook!(
      recipient,
      "configure-#{key}-webhook",
      "https://recipient.example.test/atp/#{key}"
    )

    set_webhook_active!(recipient["id"], false)

    sent =
      Atp.ConnCase.send_message!(
        sender["agent_api_key"]["token"],
        "send-#{key}",
        recipient["address"],
        Atp.ConnCase.a2a_user_text(key, "claim this webhook delivery")
      )

    message = get_message!(sent["message"]["id"])
    recipient_agent = set_webhook_active!(recipient["id"], true)

    {:ok, delivery} = WebhookDelivery.prepare(message, recipient_agent)

    {delivery, message, recipient_agent, recipient}
  end

  @spec prepare_polling_delivery!(Plug.Conn.t(), String.t()) ::
          {Delivery.t(), Message.t(), Agent.t(), Agent.t()}
  def prepare_polling_delivery!(conn, key) do
    {sender, recipient} = register_agent_pair!(conn, key)

    sent =
      Atp.ConnCase.send_message!(
        sender["agent_api_key"]["token"],
        "send-#{key}",
        recipient["address"],
        Atp.ConnCase.a2a_user_text(key, "claim this polling delivery")
      )

    delivery =
      Atp.ConnCase.claim_inbox!(recipient["agent_api_key"]["token"], "claim-#{key}", %{
        "lease_seconds" => 60
      })

    {
      get_delivery!(delivery["id"]),
      get_message!(sent["message"]["id"]),
      get_agent!(sender["id"]),
      get_agent!(recipient["id"])
    }
  end

  @spec prepare_opening_polling_delivery!(Plug.Conn.t(), String.t()) ::
          {Session.t(), Message.t(), Delivery.t(), Agent.t(), Agent.t()}
  def prepare_opening_polling_delivery!(conn, key) do
    {initiator, recipient} = register_agent_pair!(conn, key, "initiator", "recipient")

    opened =
      Atp.ConnCase.open_session!(
        initiator["agent_api_key"]["token"],
        "open-#{key}",
        recipient["address"],
        Atp.ConnCase.a2a_user_text("#{key}-opening", "open session")
      )

    delivery =
      Atp.ConnCase.claim_inbox!(recipient["agent_api_key"]["token"], "claim-#{key}", %{
        "lease_seconds" => 60
      })

    {
      get_session!(opened["session"]["id"]),
      get_message!(opened["message_status"]["message"]["id"]),
      get_delivery!(delivery["id"]),
      get_agent!(initiator["id"]),
      get_agent!(recipient["id"])
    }
  end

  @spec prepare_ordered_session_webhook_deliveries!(Plug.Conn.t(), String.t()) ::
          {Delivery.t(), Delivery.t()}
  def prepare_ordered_session_webhook_deliveries!(conn, key) do
    account = Atp.ConnCase.create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = Atp.ConnCase.register_agent!(account_token, "register-#{key}-initiator", %{})
    recipient = Atp.ConnCase.register_agent!(account_token, "register-#{key}-recipient", %{})

    Atp.ConnCase.configure_webhook!(
      recipient,
      "configure-#{key}-recipient",
      "https://recipient.example.test/atp/#{key}"
    )

    set_webhook_active!(recipient["id"], false)

    opened =
      Atp.ConnCase.open_session!(
        initiator["agent_api_key"]["token"],
        "open-#{key}",
        recipient["address"],
        Atp.ConnCase.a2a_user_text("#{key}-opening", "open ordered session")
      )

    opening_delivery =
      Atp.ConnCase.claim_inbox!(recipient["agent_api_key"]["token"], "claim-#{key}-opening", %{
        "lease_seconds" => 60
      })

    Atp.ConnCase.ack_delivery!(
      recipient["agent_api_key"]["token"],
      opening_delivery["id"],
      "ack-#{key}-opening",
      %{"status" => "accepted"}
    )

    first =
      send_session_message!(
        initiator["agent_api_key"]["token"],
        opened["session"]["id"],
        "send-#{key}-first",
        Atp.ConnCase.a2a_user_text("#{key}-first", "first ordered webhook")
      )

    second =
      send_session_message!(
        initiator["agent_api_key"]["token"],
        opened["session"]["id"],
        "send-#{key}-second",
        Atp.ConnCase.a2a_user_text("#{key}-second", "second ordered webhook")
      )

    recipient_agent = set_webhook_active!(recipient["id"], true)
    first_message = get_message!(first["message_status"]["message"]["id"])
    second_message = get_message!(second["message_status"]["message"]["id"])

    {:ok, first_delivery} = WebhookDelivery.prepare(first_message, recipient_agent)
    {:ok, second_delivery} = WebhookDelivery.prepare(second_message, recipient_agent)

    {first_delivery, second_delivery}
  end

  @spec expire_delivery_lease!(Atp.Transport.DeliveryClaim.t() | Delivery.t()) :: Delivery.t()
  def expire_delivery_lease!(%Atp.Transport.DeliveryClaim{} = claim) do
    expire_delivery_lease!(claim.delivery)
  end

  def expire_delivery_lease!(%Delivery{} = delivery) do
    delivery
    |> Ecto.Changeset.change(
      leased_until: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
    )
    |> Repo.update!()
  end

  @spec mark_message_acked!(Message.t()) :: Message.t()
  def mark_message_acked!(message) do
    message
    |> Ecto.Changeset.change(current_ack_status: "accepted")
    |> Repo.update!()
  end

  @spec expire_message!(Message.t()) :: Message.t()
  def expire_message!(message) do
    message
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
    )
    |> Repo.update!()
  end

  @spec disable_agent!(Agent.t()) :: Agent.t()
  def disable_agent!(%Agent{id: agent_id}) do
    agent_id
    |> get_agent!()
    |> Ecto.Changeset.change(status: "disabled")
    |> Repo.update!()
  end

  @spec block_sender_agent!(Agent.t(), Agent.t()) :: :ok
  def block_sender_agent!(%Agent{} = sender, %Agent{} = recipient) do
    {:ok, _policy} =
      SenderPolicies.upsert(recipient, %{
        "effect" => "block",
        "sender_agent_id" => sender.id
      })

    :ok
  end

  @spec ack_delivery_through_polling!(map(), String.t(), String.t()) :: map()
  def ack_delivery_through_polling!(recipient, claim_key, ack_key) do
    polling_delivery =
      Atp.ConnCase.claim_inbox!(recipient["agent_api_key"]["token"], claim_key, %{
        "lease_seconds" => 60
      })

    Atp.ConnCase.ack_delivery!(
      recipient["agent_api_key"]["token"],
      polling_delivery["id"],
      ack_key,
      %{"status" => "accepted"}
    )
  end

  @spec get_delivery!(String.t()) :: Delivery.t()
  def get_delivery!(delivery_id), do: Repo.get!(Delivery, delivery_id)

  @spec get_session!(String.t()) :: Session.t()
  def get_session!(session_id), do: Repo.get!(Session, session_id)

  @spec mark_session_open!(String.t()) :: Session.t()
  def mark_session_open!(session_id) do
    session_id
    |> get_session!()
    |> Ecto.Changeset.change(status: "open", opened_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()
  end

  @spec get_message!(String.t()) :: Message.t()
  def get_message!(message_id), do: Repo.get!(Message, message_id)

  @spec get_messages_for_session!(String.t()) :: [Message.t()]
  def get_messages_for_session!(session_id) do
    Message
    |> where([message], message.session_id == ^session_id)
    |> order_by([message], asc: message.session_sequence)
    |> Repo.all()
  end

  @spec get_deliveries_for_message!(String.t()) :: [Delivery.t()]
  def get_deliveries_for_message!(message_id) do
    Delivery
    |> where([delivery], delivery.message_id == ^message_id)
    |> order_by([delivery], asc: delivery.inserted_at)
    |> Repo.all()
  end

  @spec get_acks_for_message!(String.t()) :: [Ack.t()]
  def get_acks_for_message!(message_id) do
    Ack
    |> where([ack], ack.message_id == ^message_id)
    |> order_by([ack], asc: ack.inserted_at)
    |> Repo.all()
  end

  @spec get_webhook_attempt_by_delivery!(String.t()) :: WebhookAttempt.t()
  def get_webhook_attempt_by_delivery!(delivery_id) do
    Repo.get_by!(WebhookAttempt, delivery_id: delivery_id)
  end

  @spec webhook_attempt_count() :: non_neg_integer()
  def webhook_attempt_count, do: Repo.aggregate(WebhookAttempt, :count, :id)

  defp get_agent!(agent_id), do: Repo.get!(Agent, agent_id)

  defp register_agent_pair!(conn, key, sender_label \\ "sender", recipient_label \\ "recipient") do
    account = Atp.ConnCase.create_account!(conn)
    account_token = account["account_api_key"]["token"]

    sender =
      Atp.ConnCase.register_agent!(account_token, "register-#{key}-#{sender_label}", %{})

    recipient =
      Atp.ConnCase.register_agent!(account_token, "register-#{key}-#{recipient_label}", %{})

    {sender, recipient}
  end

  defp promote_to_basic!(account) do
    Atp.Identity.Account
    |> Repo.get!(account["id"])
    |> Ecto.Changeset.change(plan: "basic")
    |> Repo.update!()
  end

  defp set_webhook_active!(agent_id, active?) do
    Agent
    |> Repo.get!(agent_id)
    |> Ecto.Changeset.change(webhook_active: active?)
    |> Repo.update!()
  end

  defp send_session_message!(agent_token, session_id, key, payload) do
    build_conn()
    |> Atp.ConnCase.authorize(agent_token)
    |> Atp.ConnCase.idempotency_key(key)
    |> post("/api/sessions/#{session_id}/messages", %{"payload" => payload})
    |> json_response(201)
  end
end
