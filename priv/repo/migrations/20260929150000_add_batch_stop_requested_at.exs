defmodule AskDrive.Repo.Migrations.AddBatchStopRequestedAt do
  use Ecto.Migration

  def change do
    alter table(:batch_runs) do
      # An admin asked the running batch to stop (spec F-341); it stops at the next item
      add :stop_requested_at, :utc_datetime
    end
  end
end
