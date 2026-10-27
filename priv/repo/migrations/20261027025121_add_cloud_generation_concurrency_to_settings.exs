defmodule AskDrive.Repo.Migrations.AddCloudGenerationConcurrencyToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # chunks generated at once on a cloud API (F-840, F-841): shared with the other desks
      # that use the same API key (or Vertex project)
      add :cloud_generation_concurrency, :integer, null: false, default: 4
    end
  end
end
