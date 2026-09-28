defmodule AskDrive.Repo.Migrations.AddKindToBatchRuns do
  use Ecto.Migration

  def change do
    alter table(:batch_runs) do
      # "full" (all six phases) or "ingest_only" (sync + indexing, no QA generation) —
      # spec 6.3.8 F-331.
      add :kind, :string, default: "full", null: false
    end
  end
end
