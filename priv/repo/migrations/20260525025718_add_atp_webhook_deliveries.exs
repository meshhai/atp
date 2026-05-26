defmodule Atp.Repo.Migrations.AddAtpWebhookDeliveries do
  use Ecto.Migration

  def up do
    drop(constraint(:atp_deliveries, :atp_deliveries_mode_check))
    drop(constraint(:atp_deliveries, :atp_deliveries_status_check))

    alter table(:atp_deliveries) do
      modify(:leased_until, :utc_datetime_usec, null: true)
      add(:attempt_count, :integer, null: false, default: 0)
      add(:max_attempts, :integer)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:delivered_at, :utc_datetime_usec)
      add(:last_error, :string)
    end

    create(
      constraint(:atp_deliveries, :atp_deliveries_mode_check,
        check: "mode IN ('polling', 'webhook')"
      )
    )

    create(
      constraint(:atp_deliveries, :atp_deliveries_status_check,
        check: "status IN ('leased', 'delivered', 'retry_scheduled', 'failed')"
      )
    )

    create(index(:atp_deliveries, [:mode, :status, :next_attempt_at]))

    create table(:atp_webhook_attempts, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:delivery_id, references(:atp_deliveries, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:message_id, references(:atp_messages, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:recipient_agent_id, references(:atp_agents, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:attempt_number, :integer, null: false)
      add(:request_url, :string, null: false)
      add(:response_status, :integer)
      add(:error, :string)
      add(:result, :string, null: false)
      add(:next_attempt_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:atp_webhook_attempts, :atp_webhook_attempts_result_check,
        check: "result IN ('delivered', 'retry_scheduled', 'failed')"
      )
    )

    create(unique_index(:atp_webhook_attempts, [:delivery_id, :attempt_number]))
    create(index(:atp_webhook_attempts, [:message_id]))
    create(index(:atp_webhook_attempts, [:recipient_agent_id]))
  end

  def down do
    drop(table(:atp_webhook_attempts))
    drop(index(:atp_deliveries, [:mode, :status, :next_attempt_at]))

    drop(constraint(:atp_deliveries, :atp_deliveries_mode_check))
    drop(constraint(:atp_deliveries, :atp_deliveries_status_check))

    alter table(:atp_deliveries) do
      remove(:attempt_count)
      remove(:max_attempts)
      remove(:next_attempt_at)
      remove(:delivered_at)
      remove(:last_error)
      modify(:leased_until, :utc_datetime_usec, null: false)
    end

    create(constraint(:atp_deliveries, :atp_deliveries_mode_check, check: "mode IN ('polling')"))

    create(
      constraint(:atp_deliveries, :atp_deliveries_status_check, check: "status IN ('leased')")
    )
  end
end
