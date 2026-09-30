defmodule AskDrive.Batch.BatchRun do
  use Ecto.Schema
  import Ecto.Changeset

  schema "batch_runs" do
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :status, :string, default: "running"
    field :model_used, :string
    field :chunks_processed, :integer, default: 0
    field :qa_generated, :integer, default: 0
    field :qa_invalidated, :integer, default: 0
    field :questions_resolved, :integer, default: 0
    field :queue_remaining, :integer, default: 0
    field :error, :string
    field :kind, :string, default: "full"
    field :trigger, :string, default: "manual"
    field :progress_phase, :string
    field :progress_done, :integer, default: 0
    field :progress_total, :integer, default: 0
    field :progress_item, :string
    field :progress_detail, :string
    field :progress_phase_started_at, :utc_datetime
    field :stop_requested_at, :utc_datetime

    has_many :phase_stats, AskDrive.Batch.BatchPhaseStat, on_delete: :delete_all
    has_many :item_logs, AskDrive.Batch.ItemLog, on_delete: :delete_all

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(batch_run, attrs) do
    batch_run
    |> cast(attrs, [
      :started_at,
      :finished_at,
      :status,
      :model_used,
      :chunks_processed,
      :qa_generated,
      :qa_invalidated,
      :questions_resolved,
      :queue_remaining,
      :error,
      :kind,
      :trigger,
      :progress_phase,
      :progress_done,
      :progress_total,
      :progress_item,
      :progress_detail,
      :progress_phase_started_at,
      :stop_requested_at
    ])
    |> validate_required([:status])
    |> validate_inclusion(:kind, ["full", "ingest_only"])
    |> validate_inclusion(:trigger, ["manual", "auto"])
    |> validate_inclusion(:status, [
      "running",
      "completed",
      "deadline_reached",
      "failed",
      "aborted",
      "stopped",
      "skipped"
    ])
  end
end
