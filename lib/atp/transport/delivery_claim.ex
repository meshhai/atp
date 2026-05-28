defmodule Atp.Transport.DeliveryClaim do
  @moduledoc """
  Durable ownership lease for carrier-managed delivery work.

  A delivery claim is an internal transport contract. Runtime code may attempt
  the delivery while its claim token and lease remain current.
  """

  alias Atp.Identity.Agent
  alias Atp.Transport.{Delivery, Message}

  @enforce_keys [
    :delivery,
    :message,
    :recipient_agent,
    :claim_token,
    :leased_until,
    :attempt_number
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          delivery: Delivery.t(),
          message: Message.t(),
          recipient_agent: Agent.t(),
          claim_token: String.t(),
          leased_until: DateTime.t(),
          attempt_number: pos_integer()
        }
end
