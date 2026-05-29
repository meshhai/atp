defmodule Atp.Transport.Delivery do
  @moduledoc "Concrete ATP delivery row for polling leases and webhook attempts."

  use Ecto.Schema

  import Ecto.Changeset

  alias Atp.Identity.Agent
  alias Atp.Transport.{Message, WebhookAttempt}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @modes ~w(polling webhook)
  @statuses ~w(leased delivered retry_scheduled failed)

  schema "atp_deliveries" do
    belongs_to(:message, Message)
    belongs_to(:recipient_agent, Agent)

    field(:mode, :string)
    field(:status, :string)
    field(:claim_token, :string)
    field(:claimed_at, :utc_datetime_usec)
    field(:leased_until, :utc_datetime_usec)
    field(:attempt_count, :integer, default: 0)
    field(:max_attempts, :integer)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:delivered_at, :utc_datetime_usec)
    field(:last_error, :string)

    has_many(:webhook_attempts, WebhookAttempt)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t(),
          message_id: String.t(),
          recipient_agent_id: String.t(),
          mode: String.t(),
          status: String.t(),
          claim_token: String.t() | nil,
          claimed_at: DateTime.t() | nil,
          leased_until: DateTime.t() | nil,
          attempt_count: non_neg_integer(),
          max_attempts: pos_integer() | nil,
          next_attempt_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil,
          last_error: String.t() | nil,
          message: Message.t() | Ecto.Association.NotLoaded.t(),
          recipient_agent: Agent.t() | Ecto.Association.NotLoaded.t(),
          webhook_attempts: [WebhookAttempt.t()] | Ecto.Association.NotLoaded.t()
        }

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :message_id,
      :recipient_agent_id,
      :mode,
      :status,
      :claim_token,
      :claimed_at,
      :leased_until,
      :attempt_count,
      :max_attempts,
      :next_attempt_at,
      :delivered_at,
      :last_error
    ])
    |> validate_required([:id, :message_id, :recipient_agent_id, :mode, :status])
    |> validate_polling_lease()
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:recipient_agent_id)
  end

  defp validate_polling_lease(changeset) do
    if get_field(changeset, :mode) == "polling" do
      validate_required(changeset, [:leased_until])
    else
      changeset
    end
  end
end
