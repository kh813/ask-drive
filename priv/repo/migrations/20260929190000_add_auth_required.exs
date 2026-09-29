defmodule AskDrive.Repo.Migrations.AddAuthRequired do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Login required (spec 6.9.6, F-1308): set from the admin screen or `./app.sh auth`.
      # nil = not chosen yet (the POC default applies)
      add :auth_required, :boolean
    end
  end
end
