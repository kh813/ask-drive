defmodule AskDrive.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :name, :string
      add :picture_url, :string
      # Not a standing role: this only says the account may *attempt* to elevate.
      # Whether it currently holds admin rights lives in the session (spec 6.9.1).
      add :admin_eligible, :boolean, default: false, null: false
      add :status, :string, default: "active", null: false
      add :last_login_at, :utc_datetime
      add :last_elevated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create index(:users, [:admin_eligible])
  end
end
