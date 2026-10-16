defmodule AskDrive.Repo.Migrations.AddSetupCompletedAt do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # When the first-access web setup (spec 6.12) was completed; nil = not yet
      add :setup_completed_at, :utc_datetime
    end
  end
end
