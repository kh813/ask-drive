defmodule AskDrive.Repo.Migrations.AddDismissedAtToApiUsageLogs do
  use Ecto.Migration

  # an error an admin has marked as seen leaves the dashboard's error list (F-1411)
  def change do
    alter table(:api_usage_logs) do
      add :dismissed_at, :utc_datetime
    end

    create index(:api_usage_logs, [:status, :inserted_at])
  end
end
