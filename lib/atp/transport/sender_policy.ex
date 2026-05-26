defmodule Atp.Transport.SenderPolicy do
  @moduledoc "Recipient-owned allow/block policy for cross-account ATP senders."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.{Account, Agent}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @effects ~w(allow block)

  schema "atp_agent_sender_policies" do
    belongs_to(:recipient_agent, Agent)
    belongs_to(:sender_agent, Agent)
    belongs_to(:sender_account, Account)

    field(:effect, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          recipient_agent_id: String.t(),
          sender_agent_id: String.t() | nil,
          sender_account_id: String.t() | nil,
          effect: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:recipient_agent_id, :sender_agent_id, :sender_account_id, :effect])
    |> validate_required([:id, :recipient_agent_id, :effect])
    |> validate_inclusion(:effect, @effects)
    |> validate_exactly_one_sender_target()
    |> foreign_key_constraint(:recipient_agent_id)
    |> foreign_key_constraint(:sender_agent_id)
    |> foreign_key_constraint(:sender_account_id)
    |> unique_constraint(:sender_agent_id,
      name: :atp_agent_sender_policies_recipient_sender_agent_index
    )
    |> unique_constraint(:sender_account_id,
      name: :atp_agent_sender_policies_recipient_sender_account_index
    )
    |> check_constraint(:sender_agent_id,
      name: :atp_agent_sender_policies_exactly_one_sender_target_check
    )
  end

  defp validate_exactly_one_sender_target(changeset) do
    sender_agent_id = get_field(changeset, :sender_agent_id)
    sender_account_id = get_field(changeset, :sender_account_id)

    if present?(sender_agent_id) != present?(sender_account_id) do
      changeset
    else
      add_error(changeset, :sender_agent_id, "must set exactly one sender target")
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
