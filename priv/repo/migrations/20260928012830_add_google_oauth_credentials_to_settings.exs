defmodule AskDrive.Repo.Migrations.AddGoogleOauthCredentialsToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :google_client_id, :string
      add :google_client_secret, :string
    end
  end
end
