defmodule AskDrive.Repo.Migrations.DeskDriveOauthClient do
  use Ecto.Migration

  def change do
    # A desk's own OAuth client for Drive sync with a real Google account (spec F-346),
    # independent of the platform's Google login; the secret is encrypted like the others
    alter table(:settings) do
      add :drive_oauth_client_id, :string
      add :drive_oauth_client_secret, :binary
    end
  end
end
