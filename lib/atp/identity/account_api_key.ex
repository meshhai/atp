defmodule Atp.Identity.AccountApiKey do
  @moduledoc "Account-scoped API key for managing ATP agents."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.Account

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "atp_account_api_keys" do
    belongs_to(:account, Account)

    field(:label, :string)
    field(:token_hash, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          account_id: String.t(),
          token_hash: String.t(),
          revoked_at: DateTime.t() | nil
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(account_api_key, attrs) do
    account_api_key
    |> cast(attrs, [:account_id, :label, :token_hash, :last_used_at, :revoked_at])
    |> validate_required([:id, :account_id, :token_hash])
    |> foreign_key_constraint(:account_id)
    |> unique_constraint(:token_hash)
  end
end
