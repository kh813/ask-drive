defmodule AskDrive.Repo.Migrations.CreateDriveExclusions do
  use Ecto.Migration

  def change do
    # Files and folders the nightly batch leaves out of the index (spec F-358): set by the
    # desk's administrators ("admin") or by AskDrive itself for files it writes ("system")
    create table(:drive_exclusions) do
      add :drive_id, :string, null: false
      add :kind, :string, null: false
      add :name, :string
      add :path, :string
      add :source, :string, null: false, default: "admin"
      add :excluded_by, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:drive_exclusions, [:drive_id])

    alter table(:documents) do
      # the Drive folders a document sits in, below the sync folder, outermost first
      # (matching the folder names in its path), so a folder can be excluded from its row
      add :folder_ids, {:array, :string}
    end
  end
end
