defmodule AskDrive.Repo.Migrations.AddBatchProgress do
  use Ecto.Migration

  def change do
    alter table(:batch_runs) do
      # Where a running batch is (spec F-340): the phase, how far into it, and what it is
      # working on right now. Kept after the run ends, so an aborted run shows where it stopped.
      add :progress_phase, :string
      add :progress_done, :integer, default: 0
      add :progress_total, :integer, default: 0
      add :progress_item, :string
      add :progress_detail, :string
      add :progress_phase_started_at, :utc_datetime
    end
  end
end
