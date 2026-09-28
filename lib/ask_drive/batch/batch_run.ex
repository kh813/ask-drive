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
      :error
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, [
      "running",
      "completed",
      "deadline_reached",
      "failed",
      "aborted"
    ])
  end
end
