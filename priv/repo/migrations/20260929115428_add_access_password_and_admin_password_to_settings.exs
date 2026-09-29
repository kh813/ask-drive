defmodule AskDrive.Repo.Migrations.AddAccessPasswordAndAdminPasswordToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :access_password_hash, :string
      add :access_password_enabled, :boolean, default: false
    end
  end
end
