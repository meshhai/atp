defmodule Atp.Repo.Migrations.AllowJsonNullAtpMessagePayloads do
  use Ecto.Migration

  def change do
    alter table(:atp_messages) do
      modify(:payload, :map, null: true)
    end
  end
end
