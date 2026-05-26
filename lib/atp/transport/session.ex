defmodule Atp.Transport.Session do
  @moduledoc "Durable ATP two-party session state."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.{Account, Agent}
  alias Atp.Transport.Message

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @statuses ~w(pending open rejected failed)

  schema "atp_sessions" do
    belongs_to(:initiator_account, Account)
    belongs_to(:recipient_account, Account)
    belongs_to(:initiator_agent, Agent)
    belongs_to(:recipient_agent, Agent)
    belongs_to(:opening_message, Message)

    field(:initiator_address, :string)
    field(:recipient_address, :string)
    field(:status, :string, default: "pending")
    field(:last_sequence, :integer, default: 0)
    field(:opened_at, :utc_datetime_usec)
    field(:terminal_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          initiator_account_id: String.t(),
          recipient_account_id: String.t(),
          initiator_agent_id: String.t(),
          recipient_agent_id: String.t(),
          opening_message_id: String.t() | nil,
          initiator_address: String.t(),
          recipient_address: String.t(),
          status: String.t(),
          last_sequence: non_neg_integer(),
          opened_at: DateTime.t() | nil,
          terminal_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :initiator_account_id,
      :recipient_account_id,
      :initiator_agent_id,
      :recipient_agent_id,
      :initiator_address,
      :recipient_address,
      :status,
      :opening_message_id,
      :last_sequence,
      :opened_at,
      :terminal_at
    ])
    |> validate_required([
      :id,
      :initiator_account_id,
      :recipient_account_id,
      :initiator_agent_id,
      :recipient_agent_id,
      :initiator_address,
      :recipient_address,
      :status,
      :last_sequence
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:last_sequence, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:initiator_account_id)
    |> foreign_key_constraint(:recipient_account_id)
    |> foreign_key_constraint(:initiator_agent_id)
    |> foreign_key_constraint(:recipient_agent_id)
    |> foreign_key_constraint(:opening_message_id)
  end
end
