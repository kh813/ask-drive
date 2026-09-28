defmodule AskDrive.Repo.Migrations.AddTriggerToBatchRuns do
  use Ecto.Migration

  def change do
    alter table(:batch_runs) do
      # "manual" (admin button) or "auto" (night window). Earlier runs can't be told apart
      # and are left as "manual" (spec F-338).
      add :trigger, :string, default: "manual", null: false
    end
  end
end
