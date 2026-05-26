defmodule Atp.Repo.Migrations.CreateAtpSessions do
  use Ecto.Migration

  def change do
    create table(:atp_sessions, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:initiator_account_id, references(:atp_accounts, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:recipient_account_id, references(:atp_accounts, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:initiator_agent_id, references(:atp_agents, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:recipient_agent_id, references(:atp_agents, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:initiator_address, :string, null: false)
      add(:recipient_address, :string, null: false)
      add(:status, :string, null: false)
      add(:opening_message_id, references(:atp_messages, type: :string, on_delete: :nilify_all))
      add(:last_sequence, :bigint, null: false, default: 0)
      add(:opened_at, :utc_datetime_usec)
      add(:terminal_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:atp_sessions, :atp_sessions_status_check,
        check: "status IN ('pending', 'open', 'rejected', 'failed')"
      )
    )

    create(
      constraint(:atp_sessions, :atp_sessions_last_sequence_check, check: "last_sequence >= 0")
    )

    create(index(:atp_sessions, [:initiator_agent_id]))
    create(index(:atp_sessions, [:recipient_agent_id]))
    create(index(:atp_sessions, [:status]))

    create(
      unique_index(:atp_sessions, [:opening_message_id], where: "opening_message_id IS NOT NULL")
    )

    alter table(:atp_messages) do
      add(:session_id, references(:atp_sessions, type: :string, on_delete: :delete_all))
      add(:session_sequence, :bigint)
    end

    create(
      constraint(:atp_messages, :atp_messages_session_sequence_check,
        check:
          "(session_id IS NULL AND session_sequence IS NULL) OR (session_id IS NOT NULL AND session_sequence IS NOT NULL AND session_sequence > 0)"
      )
    )

    create(index(:atp_messages, [:session_id]))

    create(
      unique_index(:atp_messages, [:session_id, :session_sequence],
        where: "session_id IS NOT NULL"
      )
    )
  end
end
