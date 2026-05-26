defmodule Atp.Repo.Migrations.CreateAtpAcks do
  use Ecto.Migration

  def change do
    create table(:atp_acks, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:message_id, references(:atp_messages, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:delivery_id, references(:atp_deliveries, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:recipient_agent_id, references(:atp_agents, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:status, :string, null: false)
      add(:payload, :map)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(
      constraint(:atp_acks, :atp_acks_status_check,
        check: "status IN ('accepted', 'completed', 'failed', 'rejected')"
      )
    )

    create(index(:atp_acks, [:message_id]))
    create(index(:atp_acks, [:delivery_id]))
    create(index(:atp_acks, [:recipient_agent_id, :inserted_at]))
  end
end
