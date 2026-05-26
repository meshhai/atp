defmodule Atp.Identity.Account do
  @moduledoc "ATP account owned independently by the protocol service."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @plans ~w(free basic)

  schema "atp_accounts" do
    field(:name, :string)
    field(:plan, :string, default: "free")

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          plan: String.t()
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :plan])
    |> validate_required([:id, :name, :plan])
    |> validate_inclusion(:plan, @plans)
  end
end
