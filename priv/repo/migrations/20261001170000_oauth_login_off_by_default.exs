defmodule AskDrive.Repo.Migrations.OauthLoginOffByDefault do
  use Ecto.Migration

  # Google login (OAuth) starts switched off, like Secure LDAP: an administrator switches on
  # the way to sign in they set up, and only that one shows on the login page (spec F-1310).
  # New rows get "off" from the schema default (SQLite can't change a column's default).
  # Where it was never configured (no client ID in the settings or the environment), the old
  # default "on" is turned off too; a configured one keeps working.
  def up do
    if System.get_env("GOOGLE_CLIENT_ID") in [nil, ""] do
      execute "UPDATE settings SET oauth_login_enabled = 0 WHERE google_client_id IS NULL OR google_client_id = ''"
    end
  end

  def down, do: :ok
end
