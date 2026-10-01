defmodule AskDrive.Repo.Migrations.AutoBatchEnabled do
  use Ecto.Migration

  def change do
    # Whether this desk's nightly batch starts by itself (spec F-344). Existing desks keep
    # running every night; desks created from now on start switched off, while being set up.
    alter table(:settings) do
      add :auto_batch_enabled, :boolean, default: true, null: false
    end
  end
end
