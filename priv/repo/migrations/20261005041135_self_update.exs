defmodule AskDrive.Repo.Migrations.SelfUpdate do
  use Ecto.Migration

  def change do
    # Updating from the admin screen (spec F-1501): checking every night, updating by itself,
    # and what the last check / update found (platform row)
    alter table(:settings) do
      add :update_check_enabled, :boolean, default: true, null: false
      add :update_auto_apply, :boolean, default: false, null: false
      add :update_checked_at, :utc_datetime
      add :update_latest_version, :string
      add :update_last_result, :text
    end

    # why a run was stopped: "update" = paused for an update, to be continued after it
    alter table(:batch_runs) do
      add :stop_reason, :string
    end
  end
end
