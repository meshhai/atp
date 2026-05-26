defmodule Atp.Repo.Migrations.CreateAtpAgentSenderPolicies do
  use Ecto.Migration

  def change do
    create table(:atp_agent_sender_policies, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:recipient_agent_id, references(:atp_agents, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:sender_agent_id, references(:atp_agents, type: :string, on_delete: :delete_all))
      add(:sender_account_id, references(:atp_accounts, type: :string, on_delete: :delete_all))
      add(:effect, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:atp_agent_sender_policies, :atp_agent_sender_policies_effect_check,
        check: "effect IN ('allow', 'block')"
      )
    )

    create(
      constraint(
        :atp_agent_sender_policies,
        :atp_agent_sender_policies_exactly_one_sender_target_check,
        check:
          "(sender_agent_id IS NOT NULL AND sender_account_id IS NULL) OR (sender_agent_id IS NULL AND sender_account_id IS NOT NULL)"
      )
    )

    create(
      unique_index(
        :atp_agent_sender_policies,
        [:recipient_agent_id, :sender_agent_id],
        name: :atp_agent_sender_policies_recipient_sender_agent_index,
        where: "sender_agent_id IS NOT NULL"
      )
    )

    create(
      unique_index(
        :atp_agent_sender_policies,
        [:recipient_agent_id, :sender_account_id],
        name: :atp_agent_sender_policies_recipient_sender_account_index,
        where: "sender_account_id IS NOT NULL"
      )
    )
  end
end
