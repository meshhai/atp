defmodule Atp.Repo.Migrations.CreateAtpIdentity do
  use Ecto.Migration

  def change do
    create table(:atp_accounts, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :plan, :string, null: false, default: "free"

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:atp_accounts, :atp_accounts_plan_check, check: "plan IN ('free', 'basic')")

    create table(:atp_account_api_keys, primary_key: false) do
      add :id, :string, primary_key: true

      add :account_id, references(:atp_accounts, type: :string, on_delete: :delete_all),
        null: false

      add :label, :string
      add :token_hash, :string, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:atp_account_api_keys, [:token_hash])
    create index(:atp_account_api_keys, [:account_id])

    create table(:atp_agents, primary_key: false) do
      add :id, :string, primary_key: true

      add :account_id, references(:atp_accounts, type: :string, on_delete: :delete_all),
        null: false

      add :address, :string, null: false
      add :display_name, :string
      add :description, :text
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:atp_agents, :atp_agents_status_check,
             check: "status IN ('active', 'disabled')"
           )

    create unique_index(:atp_agents, [:address])
    create index(:atp_agents, [:account_id])

    create table(:atp_agent_api_keys, primary_key: false) do
      add :id, :string, primary_key: true

      add :account_id, references(:atp_accounts, type: :string, on_delete: :delete_all),
        null: false

      add :agent_id, references(:atp_agents, type: :string, on_delete: :delete_all),
        null: false

      add :label, :string
      add :token_hash, :string, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:atp_agent_api_keys, [:token_hash])
    create index(:atp_agent_api_keys, [:account_id])
    create index(:atp_agent_api_keys, [:agent_id])

    create table(:atp_idempotency_keys, primary_key: false) do
      add :id, :string, primary_key: true

      add :account_id, references(:atp_accounts, type: :string, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :route, :string, null: false
      add :request_hash, :string, null: false
      add :response_status, :integer, null: false
      add :response_body, :map, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:atp_idempotency_keys, [:account_id, :route, :key])
  end
end
