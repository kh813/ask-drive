defmodule AskDrive.Repo.Migrations.AddDriveImpersonateEmail do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Domain-wide delegation (spec F-121): the Workspace user the service account acts as.
      # Needed when the target shared drive is restricted to members of the organization,
      # which a service account (always an outside identity) can never be.
      add :drive_impersonate_email, :string
    end
  end
end
