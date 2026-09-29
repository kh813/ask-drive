defmodule AskDrive.Repo.Migrations.AddLdapLogin do
  use Ecto.Migration

  def change do
    # Sign-in with Google Secure LDAP (spec 6.13), platform-wide
    alter table(:settings) do
      add :ldap_enabled, :boolean, default: false, null: false
      add :ldap_host, :string
      add :ldap_port, :integer
      add :ldap_base_dn, :string
      # the LDAP client's certificate and key (PEM), encrypted like the other secrets
      add :ldap_client_cert, :binary
      add :ldap_client_key, :binary
      # optional: a CA for LDAP servers without a publicly trusted certificate
      add :ldap_ca_cert, :text
      # optional "access credentials" (Google) / a service bind for the user search
      add :ldap_bind_dn, :string
      add :ldap_bind_password, :binary
    end

    # Failed password sign-ins, for the lockout (per account and per source address)
    create table(:login_failures) do
      add :email, :string, null: false
      add :ip, :string
      add :reason, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:login_failures, [:email, :inserted_at])
    create index(:login_failures, [:ip, :inserted_at])
  end
end
