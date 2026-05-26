defmodule Atp.Repo.Migrations.ScopeAtpIdempotencyToPrincipals do
  use Ecto.Migration

  def up do
    drop(unique_index(:atp_idempotency_keys, [:account_id, :route, :key]))

    alter table(:atp_idempotency_keys) do
      add(:principal_type, :string, null: false, default: "account")
      add(:principal_id, :string)
      modify(:response_status, :integer, null: true)
      modify(:response_body, :map, null: true)
    end

    execute(
      "UPDATE atp_idempotency_keys SET principal_id = account_id WHERE principal_id IS NULL"
    )

    alter table(:atp_idempotency_keys) do
      modify(:principal_id, :string, null: false)
    end

    create(
      constraint(:atp_idempotency_keys, :atp_idempotency_keys_principal_type_check,
        check: "principal_type IN ('account', 'agent')"
      )
    )

    create(
      unique_index(:atp_idempotency_keys, [
        :account_id,
        :principal_type,
        :principal_id,
        :route,
        :key
      ])
    )
  end

  def down do
    drop(
      unique_index(:atp_idempotency_keys, [
        :account_id,
        :principal_type,
        :principal_id,
        :route,
        :key
      ])
    )

    drop(constraint(:atp_idempotency_keys, :atp_idempotency_keys_principal_type_check))

    alter table(:atp_idempotency_keys) do
      remove(:principal_type)
      remove(:principal_id)
      modify(:response_status, :integer, null: false)
      modify(:response_body, :map, null: false)
    end

    create(unique_index(:atp_idempotency_keys, [:account_id, :route, :key]))
  end
end
