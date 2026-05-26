defmodule Atp.Identity.Agent do
  @moduledoc "Registered ATP agent with an opaque canonical address."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.{Account, WebhookURL}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @statuses ~w(active disabled)

  schema "atp_agents" do
    belongs_to(:account, Account)

    field(:address, :string)
    field(:display_name, :string)
    field(:description, :string)
    field(:status, :string, default: "active")
    field(:webhook_url, :string)
    field(:webhook_secret, :string)
    field(:webhook_active, :boolean, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          account_id: String.t(),
          address: String.t(),
          display_name: String.t() | nil,
          description: String.t() | nil,
          status: String.t(),
          webhook_url: String.t() | nil,
          webhook_secret: String.t() | nil,
          webhook_active: boolean()
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:display_name, :description])
    |> validate_required([:id, :account_id, :address, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:display_name, max: 120)
    |> validate_length(:description, max: 2_000)
    |> foreign_key_constraint(:account_id)
    |> unique_constraint(:address)
  end

  @spec webhook_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def webhook_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:webhook_url, :webhook_secret, :webhook_active])
    |> validate_required([:webhook_url, :webhook_secret, :webhook_active])
    |> validate_length(:webhook_url, max: 2_048)
    |> validate_webhook_url()
  end

  defp validate_webhook_url(changeset) do
    validate_change(changeset, :webhook_url, fn :webhook_url, url ->
      if WebhookURL.public_http_url?(url) do
        []
      else
        [webhook_url: "must be a public http or https URL"]
      end
    end)
  end
end
