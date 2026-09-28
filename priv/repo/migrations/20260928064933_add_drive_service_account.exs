defmodule AskDrive.Repo.Migrations.AddDriveServiceAccount do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # "oauth" (default, unchanged behavior) or "service_account" — a service account needs
      # no browser OAuth round-trip, so it has none of the redirect_uri/private-IP/`.local`
      # restrictions Google imposes on the OAuth flow (spec F-110).
      add :drive_auth_mode, :string, default: "oauth", null: false
      add :drive_service_account_json, :binary
    end
  end
end
