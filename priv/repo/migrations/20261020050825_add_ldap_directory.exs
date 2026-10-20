defmodule AskDrive.Repo.Migrations.AddLdapDirectory do
  use Ecto.Migration

  def change do
    # The Secure LDAP directory's users, fetched every night, so e-mail fields are completed
    # without asking the directory on every keystroke (spec F-1313). Used in the platform
    # database only. No passwords: an address and a name.
    create table(:directory_users) do
      add :email, :string, null: false
      add :name, :string
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:directory_users, [:email])

    alter table(:settings) do
      # the last attempt, the last success, its error (nil when it worked), and which LDAP
      # settings the list was fetched with (a change makes it stale)
      add :ldap_directory_checked_at, :utc_datetime
      add :ldap_directory_synced_at, :utc_datetime
      add :ldap_directory_error, :string
      add :ldap_directory_fingerprint, :string
    end
  end
end
