defmodule Atp.Transport.DeliveryClaims do
  @moduledoc false

  import Ecto.Query

  alias Atp.Identity.ID
  alias Atp.Repo
  alias Atp.Transport.{Delivery, DeliveryClaim, Message, WebhookAttempt}
  alias Atp.Transport.WebhookDelivery.AttemptResult

  @default_webhook_claim_lease_seconds 60

  @spec claim_webhook_delivery(String.t(), keyword()) ::
          {:ok, DeliveryClaim.t() | Message.t()} | {:error, term()}
  def claim_webhook_delivery(delivery_id, opts \\ [])
      when is_binary(delivery_id) and is_list(opts) do
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_webhook_claim_lease_seconds)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    if valid_lease_seconds?(lease_seconds) do
      Repo.transaction(fn ->
        case locked_webhook_delivery(delivery_id) do
          nil ->
            Repo.rollback(:not_found)

          %Delivery{status: status, message: %Message{} = message}
          when status in ["delivered", "failed"] ->
            message

          %Delivery{status: "leased", leased_until: %DateTime{} = leased_until} = delivery ->
            if DateTime.compare(leased_until, now) == :gt do
              Repo.rollback(:delivery_in_progress)
            else
              claim_webhook_delivery!(delivery, now, lease_seconds)
            end

          %Delivery{} = delivery ->
            claim_webhook_delivery!(delivery, now, lease_seconds)
        end
      end)
    else
      {:error, :invalid_lease}
    end
  end

  @spec claim_due_webhook_delivery(keyword()) :: {:ok, DeliveryClaim.t() | nil} | {:error, term()}
  def claim_due_webhook_delivery(opts \\ []) when is_list(opts) do
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_webhook_claim_lease_seconds)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    if valid_lease_seconds?(lease_seconds) do
      Repo.transaction(fn ->
        case Repo.one(claimable_webhook_delivery_query(now)) do
          nil -> nil
          %Delivery{} = delivery -> claim_webhook_delivery!(delivery, now, lease_seconds)
        end
      end)
    else
      {:error, :invalid_lease}
    end
  end

  @spec finish_claimed_webhook_delivery(DeliveryClaim.t(), AttemptResult.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def finish_claimed_webhook_delivery(
        %DeliveryClaim{delivery: %Delivery{id: delivery_id}} = claim,
        %AttemptResult{} = result,
        opts \\ []
      )
      when is_binary(delivery_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transaction(fn ->
      case fetch_locked_webhook_claim_delivery(delivery_id) do
        nil ->
          Repo.rollback(:stale_delivery_claim)

        %Delivery{} = delivery ->
          with :ok <- validate_webhook_delivery_claim(delivery, claim, result, now) do
            insert_claimed_webhook_attempt!(claim, result)
            update_claimed_webhook_delivery!(delivery, result)
            update_claimed_webhook_message!(delivery.message, result)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp valid_lease_seconds?(seconds), do: is_integer(seconds) and seconds >= 0

  defp locked_webhook_delivery(delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id and delivery.mode == "webhook")
    |> lock("FOR UPDATE")
    |> preload([:message, :recipient_agent])
    |> Repo.one()
  end

  defp claimable_webhook_delivery_query(now) do
    Delivery
    |> join(:inner, [delivery], message in assoc(delivery, :message), as: :message)
    |> where([delivery], delivery.mode == "webhook")
    |> where(^due_webhook_delivery_filter(now))
    |> where(^webhook_session_order_filter())
    |> order_by([delivery], asc: delivery.inserted_at)
    |> limit(1)
    |> lock("FOR UPDATE SKIP LOCKED")
  end

  defp due_webhook_delivery_filter(now) do
    dynamic(
      [delivery],
      (delivery.status == "retry_scheduled" and
         (is_nil(delivery.next_attempt_at) or delivery.next_attempt_at <= ^now)) or
        (delivery.status == "leased" and not is_nil(delivery.leased_until) and
           delivery.leased_until <= ^now)
    )
  end

  defp webhook_session_order_filter do
    dynamic(
      [message: message],
      is_nil(message.session_id) or is_nil(message.session_sequence) or
        not exists(
          from(prior_delivery in Delivery,
            join: prior_message in Message,
            on: prior_message.id == prior_delivery.message_id,
            where: prior_delivery.mode == "webhook",
            where: prior_delivery.status not in ["delivered", "failed"],
            where: prior_message.session_id == parent_as(:message).session_id,
            where: prior_message.session_sequence < parent_as(:message).session_sequence,
            select: 1
          )
        )
    )
  end

  defp claim_webhook_delivery!(%Delivery{} = delivery, now, lease_seconds) do
    claim_token = ID.generate("dcl")
    leased_until = DateTime.add(now, lease_seconds, :second)
    attempt_number = delivery.attempt_count + 1

    claimed_delivery =
      delivery
      |> Ecto.Changeset.change(
        status: "leased",
        claim_token: claim_token,
        claimed_at: now,
        leased_until: leased_until
      )
      |> Repo.update!()
      |> Repo.preload([:message, :recipient_agent], force: true)

    %DeliveryClaim{
      delivery: claimed_delivery,
      message: claimed_delivery.message,
      recipient_agent: claimed_delivery.recipient_agent,
      claim_token: claim_token,
      leased_until: leased_until,
      attempt_number: attempt_number
    }
  end

  defp fetch_locked_webhook_claim_delivery(delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id)
    |> where([delivery], delivery.mode == "webhook")
    |> join(:inner, [delivery], message in assoc(delivery, :message))
    |> preload([_delivery, message], message: message)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp validate_webhook_delivery_claim(
         %Delivery{} = delivery,
         %DeliveryClaim{} = claim,
         %AttemptResult{} = result,
         now
       ) do
    cond do
      delivery.id != claim.delivery.id ->
        {:error, :stale_delivery_claim}

      delivery.message_id != claim.message.id ->
        {:error, :stale_delivery_claim}

      delivery.recipient_agent_id != claim.recipient_agent.id ->
        {:error, :stale_delivery_claim}

      delivery.status != "leased" ->
        {:error, :stale_delivery_claim}

      delivery.claim_token != claim.claim_token ->
        {:error, :stale_delivery_claim}

      not current_webhook_claim_lease?(delivery, claim, now) ->
        {:error, :stale_delivery_claim}

      result.attempt_number != claim.attempt_number ->
        {:error, :stale_delivery_claim}

      true ->
        :ok
    end
  end

  defp current_webhook_claim_lease?(
         %Delivery{leased_until: %DateTime{} = leased_until},
         %DeliveryClaim{leased_until: %DateTime{} = claimed_leased_until},
         now
       ) do
    DateTime.compare(leased_until, claimed_leased_until) == :eq and
      DateTime.compare(leased_until, now) == :gt
  end

  defp current_webhook_claim_lease?(%Delivery{}, %DeliveryClaim{}, _now), do: false

  defp insert_claimed_webhook_attempt!(%DeliveryClaim{} = claim, %AttemptResult{} = result) do
    %WebhookAttempt{id: ID.generate("wha")}
    |> WebhookAttempt.changeset(%{
      delivery_id: claim.delivery.id,
      message_id: claim.message.id,
      recipient_agent_id: claim.recipient_agent.id,
      attempt_number: result.attempt_number,
      request_url: claim.recipient_agent.webhook_url,
      response_status: result.response_status,
      error: result.error,
      result: result.result,
      next_attempt_at: result.next_attempt_at
    })
    |> Repo.insert!()
  end

  defp update_claimed_webhook_delivery!(%Delivery{} = delivery, %AttemptResult{} = result) do
    delivery
    |> Ecto.Changeset.change(
      attempt_count: result.attempt_number,
      status: result.delivery_status,
      claim_token: nil,
      claimed_at: nil,
      leased_until: nil,
      next_attempt_at: result.next_attempt_at,
      delivered_at: result.delivered_at,
      last_error: result.error
    )
    |> Repo.update!()
  end

  defp update_claimed_webhook_message!(%Message{} = message, %AttemptResult{
         message_status: message_status
       }) do
    now = DateTime.utc_now(:microsecond)

    Message
    |> where([persisted_message], persisted_message.id == ^message.id)
    |> where([persisted_message], persisted_message.carrier_status != "delivered")
    |> Repo.update_all(set: [carrier_status: message_status, updated_at: now])

    Repo.get!(Message, message.id)
  end
end
