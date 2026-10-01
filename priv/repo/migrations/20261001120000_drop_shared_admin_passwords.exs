defmodule AskDrive.Repo.Migrations.DropSharedAdminPasswords do
  use Ecto.Migration

  def change do
    # Platform Admin has no shared password any more — administrators confirm it is them
    # with their own account (spec 6.9) — and the desks' own passwords went before (F-1113).
    # Dropping the columns removes the stored digests too.
    alter table(:settings) do
      remove :admin_password_hash, :string
      remove :admin_max_attempts, :integer, default: 5
      remove :admin_lockout_minutes, :integer, default: 15
      remove :app_admin_password_hash, :string
      remove :app_admin_password_reset_at, :utc_datetime
      remove :app_admin_password_reset_by, :string
    end
  end
end
