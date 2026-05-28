defmodule Atp.Repo.Migrations.AddAtpDeliveryClaimFields do
  use Ecto.Migration

  def change do
    alter table(:atp_deliveries) do
      add(:claim_token, :string)
      add(:claimed_at, :utc_datetime_usec)
    end
  end
end
