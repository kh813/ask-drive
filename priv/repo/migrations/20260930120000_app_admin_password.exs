defmodule AskDrive.Repo.Migrations.AppAdminPassword do
  use Ecto.Migration

  def change do
    # The app's own administrator password (spec F-1113), separate from the platform one
    # (the primary app shares its settings row with the platform)
    alter table(:settings) do
      add :app_admin_password_hash, :string
      add :app_admin_password_reset_at, :utc_datetime
      add :app_admin_password_reset_by, :string
    end

    # which app an elevation-log row is about (nil = the platform)
    alter table(:admin_elevation_logs) do
      add :app_slug, :string
    end
  end
end
