defmodule Atp.Transport.WebhookAttempt do
  @moduledoc "Audit row for one ATP webhook delivery attempt."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.Agent
  alias Atp.Transport.{Delivery, Message}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @results ~w(delivered retry_scheduled failed)

  schema "atp_webhook_attempts" do
    belongs_to(:delivery, Delivery)
    belongs_to(:message, Message)
    belongs_to(:recipient_agent, Agent)

    field(:attempt_number, :integer)
    field(:request_url, :string)
    field(:response_status, :integer)
    field(:error, :string)
    field(:result, :string)
    field(:next_attempt_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          delivery_id: String.t(),
          message_id: String.t(),
          recipient_agent_id: String.t(),
          attempt_number: pos_integer(),
          request_url: String.t(),
          response_status: non_neg_integer() | nil,
          error: String.t() | nil,
          result: String.t(),
          next_attempt_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :delivery_id,
      :message_id,
      :recipient_agent_id,
      :attempt_number,
      :request_url,
      :response_status,
      :error,
      :result,
      :next_attempt_at
    ])
    |> validate_required([
      :id,
      :delivery_id,
      :message_id,
      :recipient_agent_id,
      :attempt_number,
      :request_url,
      :result
    ])
    |> validate_number(:attempt_number, greater_than: 0)
    |> validate_inclusion(:result, @results)
    |> foreign_key_constraint(:delivery_id)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:recipient_agent_id)
    |> unique_constraint(:attempt_number,
      name: :atp_webhook_attempts_delivery_id_attempt_number_index
    )
  end
end
