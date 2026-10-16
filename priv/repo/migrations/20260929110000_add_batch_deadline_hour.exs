defmodule AskDrive.Repo.Migrations.AddBatchDeadlineHour do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # When a running batch stops generating (spec F-339). Separate from batch_end_hour,
      # which now only bounds when the automatic run may *start*: a run starting at 06:43
      # (after a late restart) was cut off at 07:00 after 16 minutes.
      add :batch_deadline_hour, :integer, default: 8, null: false
    end
  end
end
