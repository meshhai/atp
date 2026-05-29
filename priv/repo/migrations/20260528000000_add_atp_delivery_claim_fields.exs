defmodule Atp.Repo.Migrations.AddAtpDeliveryClaimFields do
  use Ecto.Migration

  def change do
    alter table(:atp_deliveries) do
      add(:claim_token, :string)
      add(:claimed_at, :utc_datetime_usec)
    end

    create(
      index(:atp_deliveries, [:next_attempt_at, :inserted_at],
        name: :atp_deliveries_due_webhook_retry_idx,
        where: "mode = 'webhook' AND status = 'retry_scheduled'"
      )
    )

    create(
      index(:atp_deliveries, [:leased_until, :inserted_at],
        name: :atp_deliveries_due_webhook_lease_idx,
        where: "mode = 'webhook' AND status = 'leased'"
      )
    )
  end
end
