defmodule AskDrive.Repo.Migrations.AppAdminEvents do
  use Ecto.Migration

  def change do
    # whose app-admin assignment a row records (spec F-1114): added / removed
    alter table(:admin_elevation_logs) do
      add :target_email, :string
    end
  end
end
