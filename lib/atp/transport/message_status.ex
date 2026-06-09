defmodule Atp.Transport.MessageStatus do
  @moduledoc "Explicit read model for public ATP message delivery status."

  alias Atp.Identity.{Account, Agent}
  alias Atp.Transport.{Delivery, Message}

  @enforce_keys [:message, :deliveries, :expose_webhook_request_url?]
  defstruct [:message, :deliveries, :expose_webhook_request_url?]

  @type viewer :: Agent.t() | Account.t()
  @type t :: %__MODULE__{
          message: Message.t(),
          deliveries: [Delivery.t()],
          expose_webhook_request_url?: boolean()
        }

  @spec from_preloaded_message(Message.t(), viewer()) :: t()
  def from_preloaded_message(%Message{deliveries: deliveries} = message, viewer)
      when is_list(deliveries) do
    :ok = ensure_attempts_preloaded(deliveries)

    %__MODULE__{
      message: message,
      deliveries: deliveries,
      expose_webhook_request_url?: expose_webhook_request_url?(message, viewer)
    }
  end

  def from_preloaded_message(%Message{}, _viewer) do
    raise ArgumentError, "message status requires preloaded deliveries"
  end

  defp ensure_attempts_preloaded(deliveries) do
    if Enum.all?(deliveries, &is_list(&1.webhook_attempts)) do
      :ok
    else
      raise ArgumentError, "message status requires preloaded webhook attempts"
    end
  end

  defp expose_webhook_request_url?(%Message{} = message, %Agent{} = viewer) do
    message.recipient_agent_id == viewer.id
  end

  defp expose_webhook_request_url?(%Message{} = message, %Account{} = viewer) do
    message.recipient_account_id == viewer.id
  end
end
