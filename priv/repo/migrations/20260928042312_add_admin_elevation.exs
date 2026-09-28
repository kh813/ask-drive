defmodule AskDrive.Repo.Migrations.AddAdminElevation do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # PBKDF2-HMAC-SHA512 digest, never the password itself (spec 9.6 N-613).
      add :admin_password_hash, :string
      add :admin_session_minutes, :integer, default: 30, null: false
      add :admin_max_attempts, :integer, default: 5, null: false
      add :admin_lockout_minutes, :integer, default: 15, null: false
    end

    create table(:admin_elevation_logs) do
      # Deleting a user must not erase the record of what they did, so the reference is
      # nullable and the address is denormalised alongside it (spec 7.1.2).
      add :user_id, references(:users, on_delete: :nilify_all)
      add :email, :string, null: false
      add :event, :string, null: false
      add :ip_address, :string
      add :user_agent, :string
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:admin_elevation_logs, [:occurred_at])
    create index(:admin_elevation_logs, [:user_id])
    create index(:admin_elevation_logs, [:email, :event, :occurred_at])
  end
end
