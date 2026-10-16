defmodule AskDrive.Repo.Migrations.AddOauthLoginEnabled do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Google login (OAuth) on/off (spec F-1310), independent of its credentials and of
      # Drive sync's OAuth. On by default: sign-in keeps working where it was configured.
      add :oauth_login_enabled, :boolean, default: true, null: false
    end
  end
end
