defmodule Atp.Transport.Ack do
  @moduledoc "Append-only ATP recipient ACK event for a delivered message."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.Agent
  alias Atp.Transport.{Delivery, JsonValue, Message}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @statuses ~w(accepted completed failed rejected)

  schema "atp_acks" do
    belongs_to(:message, Message)
    belongs_to(:delivery, Delivery)
    belongs_to(:recipient_agent, Agent)

    field(:status, :string)
    field(:payload, JsonValue)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          message_id: String.t(),
          delivery_id: String.t(),
          recipient_agent_id: String.t(),
          status: String.t(),
          payload: JsonValue.t(),
          inserted_at: DateTime.t() | nil
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(ack, attrs) do
    ack
    |> cast(attrs, [:message_id, :delivery_id, :recipient_agent_id, :status, :payload])
    |> validate_required([:id, :message_id, :delivery_id, :recipient_agent_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:delivery_id)
    |> foreign_key_constraint(:recipient_agent_id)
  end
end
