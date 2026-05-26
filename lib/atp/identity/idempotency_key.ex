defmodule Atp.Identity.IdempotencyKey do
  @moduledoc "Stored write response for account-scoped idempotency keys."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.Account

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "atp_idempotency_keys" do
    belongs_to(:account, Account)

    field(:key, :string)
    field(:principal_id, :string)
    field(:principal_type, :string)
    field(:request_hash, :string)
    field(:response_body, :map)
    field(:response_status, :integer)
    field(:route, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          account_id: String.t(),
          key: String.t(),
          principal_id: String.t(),
          principal_type: String.t(),
          route: String.t(),
          request_hash: String.t(),
          response_status: non_neg_integer() | nil,
          response_body: map() | nil
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(idempotency_key, attrs) do
    idempotency_key
    |> cast(attrs, [
      :account_id,
      :principal_id,
      :principal_type,
      :key,
      :route,
      :request_hash,
      :response_status,
      :response_body
    ])
    |> validate_required([
      :id,
      :account_id,
      :principal_id,
      :principal_type,
      :key,
      :route,
      :request_hash,
      :response_status,
      :response_body
    ])
    |> validate_inclusion(:principal_type, ~w(account agent))
    |> foreign_key_constraint(:account_id)
    |> unique_constraint([:account_id, :principal_type, :principal_id, :route, :key])
  end

  @spec completion_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def completion_changeset(idempotency_key, attrs) do
    idempotency_key
    |> cast(attrs, [:response_status, :response_body])
    |> validate_required([:response_status, :response_body])
  end
end
