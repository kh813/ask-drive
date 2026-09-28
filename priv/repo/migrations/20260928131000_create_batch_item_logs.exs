defmodule AskDrive.Repo.Migrations.CreateBatchItemLogs do
  use Ecto.Migration

  def change do
    # One row per file per batch phase (spec 6.3.5): what happened to each Drive file during
    # sync and indexing, and why, so "synced 4 files, indexed 0" can be explained from the
    # admin screen instead of from the server log.
    create table(:batch_item_logs) do
      add :batch_run_id, references(:batch_runs, on_delete: :delete_all)
      add :phase, :string, null: false
      add :document_id, :integer
      add :drive_file_id, :string
      add :name, :string
      add :mime_type, :string
      add :status, :string, null: false
      add :chunks, :integer
      add :message, :text
      add :duration_ms, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:batch_item_logs, [:batch_run_id])
  end
end
