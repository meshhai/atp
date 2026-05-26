defmodule Atp.Repo.Migrations.AddAtpAgentWebhookEndpoint do
  use Ecto.Migration

  def change do
    alter table(:atp_agents) do
      add(:webhook_url, :string)
      add(:webhook_secret, :string)
      add(:webhook_active, :boolean, null: false, default: false)
    end
  end
end
