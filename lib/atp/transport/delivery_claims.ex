defmodule Atp.Transport.DeliveryClaims do
  @moduledoc false

  alias Atp.Transport.{Delivery, DeliveryClaim, DurableLedger}
  alias Atp.Transport.WebhookDelivery.AttemptResult

  @spec claim_webhook_delivery(String.t()) :: DurableLedger.claim_result()
  def claim_webhook_delivery(delivery_id) when is_binary(delivery_id) do
    DurableLedger.claim_webhook_delivery(delivery_id, [])
  end

  @spec claim_webhook_delivery(String.t(), keyword()) :: DurableLedger.claim_result()
  def claim_webhook_delivery(delivery_id, opts) when is_binary(delivery_id) and is_list(opts) do
    DurableLedger.claim_webhook_delivery(delivery_id, opts)
  end

  @spec claim_due_webhook_delivery() :: DurableLedger.due_claim_result()
  def claim_due_webhook_delivery do
    DurableLedger.claim_due_webhook_delivery([])
  end

  @spec claim_due_webhook_delivery(keyword()) :: DurableLedger.due_claim_result()
  def claim_due_webhook_delivery(opts) when is_list(opts) do
    DurableLedger.claim_due_webhook_delivery(opts)
  end

  @spec finish_claimed_webhook_delivery(DeliveryClaim.t(), AttemptResult.t(), keyword()) ::
          DurableLedger.finish_result()
  def finish_claimed_webhook_delivery(
        %DeliveryClaim{delivery: %Delivery{id: delivery_id}} = claim,
        %AttemptResult{} = result,
        opts \\ []
      )
      when is_binary(delivery_id) and is_list(opts) do
    DurableLedger.finish_claimed_webhook_delivery(claim, result, opts)
  end

  @spec terminalize_claimed_webhook_delivery(
          DeliveryClaim.t(),
          DurableLedger.terminalization_reason(),
          keyword()
        ) :: DurableLedger.finish_result()
  def terminalize_claimed_webhook_delivery(
        %DeliveryClaim{delivery: %Delivery{id: delivery_id}} = claim,
        reason,
        opts \\ []
      )
      when is_binary(delivery_id) and reason in [:message_acked, :message_expired] and
             is_list(opts) do
    DurableLedger.terminalize_claimed_webhook_delivery(claim, reason, opts)
  end
end
