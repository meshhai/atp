defmodule Atp.DeliveryClaimTest do
  use Atp.ConnCase, async: false

  alias Atp.Identity.Agent
  alias Atp.Repo
  alias Atp.Transport
  alias Atp.Transport.{Delivery, DeliveryClaim, Message, WebhookDelivery}

  test "claims a due webhook delivery with explicit durable ownership", %{conn: conn} do
    {delivery, message, recipient_agent} = prepare_due_webhook_delivery!(conn, "claim-success")

    assert {:ok, %DeliveryClaim{} = claim} =
             Transport.claim_due_webhook_delivery(lease_seconds: 90)

    assert %Delivery{message: %Message{}, recipient_agent: %Agent{}} = claim.delivery
    assert claim.delivery.id == delivery.id
    assert claim.message.id == message.id
    assert claim.recipient_agent.id == recipient_agent.id
    assert claim.claim_token =~ "dcl_"
    assert claim.delivery.claim_token == claim.claim_token
    assert %DateTime{} = claim.delivery.claimed_at
    assert DateTime.diff(claim.leased_until, claim.delivery.claimed_at, :second) == 90
    assert claim.attempt_number == 1

    persisted = Repo.get!(Delivery, delivery.id)

    assert persisted.status == "leased"
    assert persisted.claim_token == claim.claim_token
    assert persisted.claimed_at == claim.delivery.claimed_at
    assert persisted.leased_until == claim.leased_until
    assert persisted.attempt_count == 0
  end

  test "concurrent due webhook claimers cannot receive the same delivery", %{conn: conn} do
    {delivery, _message, _recipient_agent} = prepare_due_webhook_delivery!(conn, "claim-race")

    results =
      1..2
      |> Task.async_stream(
        fn _index -> Transport.claim_due_webhook_delivery(lease_seconds: 60) end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    claims = for {:ok, %DeliveryClaim{} = claim} <- results, do: claim

    assert [%DeliveryClaim{} = claim] = claims
    assert claim.delivery.id == delivery.id
    assert Enum.count(results, &(&1 == {:ok, nil})) == 1
  end

  test "polling inbox claims remain unchanged", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-polling-claim-sender", %{})
    recipient = register_agent!(account_token, "register-polling-claim-recipient", %{})

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-polling-claim",
        recipient["address"],
        a2a_user_text("polling-claim", "polling delivery still leases")
      )

    claimed =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-polling-claim", %{
        "lease_seconds" => 60
      })

    assert claimed["message"]["id"] == sent["message"]["id"]
    assert claimed["id"] =~ "dlv_"
    assert {:ok, _leased_until, 0} = DateTime.from_iso8601(claimed["leased_until"])
    refute Map.has_key?(claimed, "claim_token")
    refute Map.has_key?(claimed, "claimed_at")

    persisted = Repo.get!(Delivery, claimed["id"])

    assert persisted.mode == "polling"
    assert persisted.status == "leased"
    assert is_nil(persisted.claim_token)
    assert is_nil(persisted.claimed_at)
  end

  defp prepare_due_webhook_delivery!(conn, key) do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-#{key}-sender", %{})
    recipient = register_agent!(account_token, "register-#{key}-recipient", %{})

    configure_webhook!(
      recipient,
      "configure-#{key}-webhook",
      "https://recipient.example.test/atp/#{key}"
    )

    set_webhook_active!(recipient["id"], false)

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-#{key}",
        recipient["address"],
        a2a_user_text(key, "claim this webhook delivery")
      )

    message = Repo.get!(Message, sent["message"]["id"])
    recipient_agent = set_webhook_active!(recipient["id"], true)

    assert {:ok, delivery} = WebhookDelivery.prepare(message, recipient_agent)

    {delivery, message, recipient_agent}
  end

  defp set_webhook_active!(agent_id, active?) do
    Agent
    |> Repo.get!(agent_id)
    |> Ecto.Changeset.change(webhook_active: active?)
    |> Repo.update!()
  end
end
