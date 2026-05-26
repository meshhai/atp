defmodule Atp.Repo.Migrations.EnforceOneActiveAtpAgentKey do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE atp_agent_api_keys AS key
    SET revoked_at = COALESCE(key.revoked_at, NOW()),
        updated_at = NOW()
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY agent_id
               ORDER BY inserted_at DESC, id DESC
             ) AS active_rank
      FROM atp_agent_api_keys
      WHERE revoked_at IS NULL
    ) AS ranked
    WHERE key.id = ranked.id
      AND ranked.active_rank > 1
    """)

    create(
      unique_index(:atp_agent_api_keys, [:agent_id],
        name: :atp_agent_api_keys_one_active_per_agent_index,
        where: "revoked_at IS NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:atp_agent_api_keys, [:agent_id],
        name: :atp_agent_api_keys_one_active_per_agent_index
      )
    )
  end
end
