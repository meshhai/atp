defmodule Atp.Transport.Message do
  @moduledoc "Durable ATP message envelope and cached transport state."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.{Account, Agent}
  alias Atp.Transport.Session

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @trust_values ~w(trusted untrusted)
  @carrier_statuses ~w(queued delivered delivery_failed expired rejected)
  @ack_statuses ~w(accepted completed failed rejected)

  schema "atp_messages" do
    belongs_to(:sender_account, Account)
    belongs_to(:recipient_account, Account)
    belongs_to(:sender_agent, Agent)
    belongs_to(:recipient_agent, Agent)
    belongs_to(:session, Session)

    field(:sender_address, :string)
    field(:recipient_address, :string)
    field(:trust, :string)
    field(:payload, Atp.Transport.JsonValue)
    field(:content_type, :string)
    field(:carrier_status, :string, default: "queued")
    field(:current_ack_status, :string)
    field(:terminal_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:session_sequence, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          sender_account_id: String.t(),
          recipient_account_id: String.t(),
          sender_agent_id: String.t(),
          recipient_agent_id: String.t(),
          session_id: String.t() | nil,
          sender_address: String.t(),
          recipient_address: String.t(),
          trust: String.t(),
          payload: term(),
          content_type: String.t(),
          carrier_status: String.t(),
          current_ack_status: String.t() | nil,
          terminal_at: DateTime.t() | nil,
          expires_at: DateTime.t(),
          session_sequence: pos_integer() | nil,
          inserted_at: DateTime.t() | nil
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :sender_account_id,
      :recipient_account_id,
      :sender_agent_id,
      :recipient_agent_id,
      :session_id,
      :sender_address,
      :recipient_address,
      :trust,
      :payload,
      :content_type,
      :carrier_status,
      :current_ack_status,
      :terminal_at,
      :expires_at,
      :session_sequence
    ])
    |> validate_required([
      :id,
      :sender_account_id,
      :recipient_account_id,
      :sender_agent_id,
      :recipient_agent_id,
      :sender_address,
      :recipient_address,
      :trust,
      :content_type,
      :carrier_status,
      :expires_at
    ])
    |> validate_inclusion(:trust, @trust_values)
    |> validate_inclusion(:carrier_status, @carrier_statuses)
    |> validate_inclusion(:current_ack_status, @ack_statuses)
    |> validate_number(:session_sequence, greater_than: 0)
    |> foreign_key_constraint(:sender_account_id)
    |> foreign_key_constraint(:recipient_account_id)
    |> foreign_key_constraint(:sender_agent_id)
    |> foreign_key_constraint(:recipient_agent_id)
    |> foreign_key_constraint(:session_id)
  end
end
