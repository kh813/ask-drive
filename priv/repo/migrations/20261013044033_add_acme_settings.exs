defmodule AskDrive.Repo.Migrations.AddAcmeSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Let's Encrypt certificate by DNS-01 through the Value-Domain DNS API (spec F-1009,
      # platform row): what to get, the API key (encrypted), and what the last run found.
      add :acme_enabled, :boolean, default: false, null: false
      add :acme_hostname, :string
      add :acme_dns_zone, :string
      add :acme_email, :string
      add :acme_staging, :boolean, default: false, null: false
      add :valuedomain_api_key, :binary
      add :acme_checked_at, :utc_datetime
      add :acme_last_ok, :boolean
      add :acme_last_result, :text
    end
  end
end
