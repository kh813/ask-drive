defmodule AskDrive.Repo.Migrations.CreateAppAdmins do
  use Ecto.Migration

  def change do
    create table(:app_admins) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :app_slug, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_admins, [:user_id, :app_slug])
    create index(:app_admins, [:user_id])
    create index(:app_admins, [:app_slug])
  end
end
