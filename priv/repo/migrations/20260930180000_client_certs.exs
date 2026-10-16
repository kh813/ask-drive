defmodule AskDrive.Repo.Migrations.ClientCerts do
  use Ecto.Migration

  def change do
    # Access restricted to devices with a certificate issued by AskDrive (spec 6.14)
    create table(:client_cert_groups) do
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:client_cert_groups, [:name])

    create table(:client_certs) do
      add :group_id, references(:client_cert_groups, on_delete: :delete_all), null: false
      add :serial, :string, null: false
      add :not_before, :utc_datetime
      add :not_after, :utc_datetime
      add :issued_by, :string
      add :revoked_at, :utc_datetime
      add :revoked_by, :string
      add :last_seen_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:client_certs, [:serial])

    # monitor mode: who comes with a certificate and who still doesn't
    alter table(:users) do
      add :client_cert_seen_at, :utc_datetime
      add :no_client_cert_seen_at, :utc_datetime
    end
  end
end
