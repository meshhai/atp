defmodule Atp.Transport.DurableLedger.Postgres do
  @moduledoc """
  Default durable ledger adapter backed by Postgres/Ecto.

  Ecto and database locking remain implementation details of the current
  delivery claim implementation. This adapter exposes only the carrier
  operations defined by `Atp.Transport.DurableLedger`.
  """

  @behaviour Atp.Transport.DurableLedger

  alias Atp.Transport.{DeliveryClaim, DeliveryClaims, Message}
  alias Atp.Transport.WebhookDelivery.AttemptResult

  @impl true
  @spec claim_due_webhook_delivery(keyword()) ::
          {:ok, DeliveryClaim.t() | nil} | {:error, term()}
  defdelegate claim_due_webhook_delivery(opts), to: DeliveryClaims

  @impl true
  @spec claim_webhook_delivery(String.t(), keyword()) ::
          {:ok, DeliveryClaim.t() | Message.t()} | {:error, term()}
  defdelegate claim_webhook_delivery(delivery_id, opts), to: DeliveryClaims

  @impl true
  @spec finish_claimed_webhook_delivery(DeliveryClaim.t(), AttemptResult.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  defdelegate finish_claimed_webhook_delivery(claim, result, opts), to: DeliveryClaims

  @impl true
  @spec terminalize_claimed_webhook_delivery(
          DeliveryClaim.t(),
          Atp.Transport.DurableLedger.terminalization_reason(),
          keyword()
        ) :: {:ok, Message.t()} | {:error, term()}
  defdelegate terminalize_claimed_webhook_delivery(claim, reason, opts), to: DeliveryClaims
end
