defmodule Atp.Repo.Migrations.CreateAtpTransport do
  use Ecto.Migration

  def change do
    create table(:atp_messages, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:sender_account_id, references(:atp_accounts, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:recipient_account_id, references(:atp_accounts, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:sender_agent_id, references(:atp_agents, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:recipient_agent_id, references(:atp_agents, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:sender_address, :string, null: false)
      add(:recipient_address, :string, null: false)
      add(:trust, :string, null: false)
      add(:payload, :map, null: false)
      add(:content_type, :string, null: false)
      add(:carrier_status, :string, null: false)
      add(:current_ack_status, :string)
      add(:terminal_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:atp_messages, :atp_messages_trust_check,
        check: "trust IN ('trusted', 'untrusted')"
      )
    )

    create(
      constraint(:atp_messages, :atp_messages_carrier_status_check,
        check:
          "carrier_status IN ('queued', 'delivered', 'delivery_failed', 'expired', 'rejected')"
      )
    )

    create(
      constraint(:atp_messages, :atp_messages_current_ack_status_check,
        check:
          "current_ack_status IS NULL OR current_ack_status IN ('accepted', 'completed', 'failed', 'rejected')"
      )
    )

    create(index(:atp_messages, [:sender_agent_id]))
    create(index(:atp_messages, [:recipient_agent_id, :carrier_status, :expires_at]))
    create(index(:atp_messages, [:recipient_account_id]))

    create table(:atp_deliveries, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:message_id, references(:atp_messages, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:recipient_agent_id, references(:atp_agents, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:mode, :string, null: false)
      add(:status, :string, null: false)
      add(:leased_until, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:atp_deliveries, :atp_deliveries_mode_check, check: "mode IN ('polling')"))

    create(
      constraint(:atp_deliveries, :atp_deliveries_status_check, check: "status IN ('leased')")
    )

    create(index(:atp_deliveries, [:message_id]))
    create(index(:atp_deliveries, [:recipient_agent_id, :status, :leased_until]))
  end
end
