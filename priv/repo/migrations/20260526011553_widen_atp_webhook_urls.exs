defmodule Atp.Repo.Migrations.WidenAtpWebhookUrls do
  use Ecto.Migration

  def change do
    alter table(:atp_agents) do
      modify(:webhook_url, :text, from: :string)
    end

    alter table(:atp_webhook_attempts) do
      modify(:request_url, :text, from: :string)
    end
  end
end
