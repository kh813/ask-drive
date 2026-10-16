defmodule AskDrive.Repo.Migrations.LoginLocks do
  use Ecto.Migration

  def change do
    # the connection environment a failure came from (spec F-1305): the browser's device
    # cookie, or a hash of address + User-Agent + Accept-Language without one
    alter table(:login_failures) do
      add :env_key, :string
      add :user_agent, :string
    end

    create index(:login_failures, [:env_key, :inserted_at])

    # active lockouts: "account" (5 failures in 5 min → 15 min) or "env" (10 in 24 h → 24 h)
    create table(:login_locks) do
      add :scope, :string, null: false
      add :key, :string, null: false
      add :email, :string
      add :ip, :string
      add :user_agent, :string
      add :locked_until, :utc_datetime, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:login_locks, [:scope, :key, :locked_until])
  end
end
