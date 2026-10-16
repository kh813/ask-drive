defmodule AskDrive.Repo.Migrations.CreateApps do
  use Ecto.Migration

  def change do
    # Registry of AskDrive apps on this platform (spec 6.11), e.g. IT-Support and HR, each
    # with its own Drive folder, Gemini key and index. Lives in the platform database; every
    # database shares one schema, so app databases carry an unused, empty copy.
    create table(:apps) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :text
      # nil for the primary app, whose data is the platform database itself
      add :db_path, :string
      add :primary, :boolean, default: false, null: false
      add :position, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:apps, [:slug])
  end
end
