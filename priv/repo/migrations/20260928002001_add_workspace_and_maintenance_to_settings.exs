defmodule AskDrive.Repo.Migrations.AddWorkspaceAndMaintenanceToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :allowed_domain, :string
      add :maintenance_mode, :boolean, default: false, null: false
      add :maintenance_message, :string
    end
  end
end
