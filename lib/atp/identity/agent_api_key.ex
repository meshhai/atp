defmodule Atp.Identity.AgentApiKey do
  @moduledoc "Agent-scoped API key for acting as one ATP agent."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.{Account, Agent}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "atp_agent_api_keys" do
    belongs_to(:account, Account)
    belongs_to(:agent, Agent)

    field(:label, :string)
    field(:token_hash, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          account_id: String.t(),
          agent_id: String.t(),
          token_hash: String.t(),
          revoked_at: DateTime.t() | nil
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(agent_api_key, attrs) do
    agent_api_key
    |> cast(attrs, [:account_id, :agent_id, :label, :token_hash, :last_used_at, :revoked_at])
    |> validate_required([:id, :account_id, :agent_id, :token_hash])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:agent_id, name: :atp_agent_api_keys_one_active_per_agent_index)
  end
end
