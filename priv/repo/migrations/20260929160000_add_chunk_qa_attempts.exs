defmodule AskDrive.Repo.Migrations.AddChunkQaAttempts do
  use Ecto.Migration

  def change do
    alter table(:chunks) do
      # QA generation failures of this chunk (spec F-342): failed chunks go to the back of
      # the queue, and after 3 failures they are skipped until an admin puts them back
      add :qa_attempts, :integer, default: 0, null: false
      add :qa_error, :string
      add :qa_attempted_at, :utc_datetime
    end
  end
end
