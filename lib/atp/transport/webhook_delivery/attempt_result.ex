defmodule Atp.Transport.WebhookDelivery.AttemptResult do
  @moduledoc """
  Typed result of one webhook delivery HTTP attempt.

  Webhook-specific code owns request execution and classification. The durable
  claim layer persists this result only after validating claim ownership.
  """

  @enforce_keys [
    :attempt_number,
    :response_status,
    :error,
    :result,
    :delivery_status,
    :message_status,
    :next_attempt_at,
    :delivered_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          attempt_number: pos_integer(),
          response_status: non_neg_integer() | nil,
          error: String.t() | nil,
          result: String.t(),
          delivery_status: String.t(),
          message_status: String.t(),
          next_attempt_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil
        }
end
