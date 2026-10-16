defmodule AskDrive.Batch.BatchPhaseStat do
  use Ecto.Schema
  import Ecto.Changeset

  schema "batch_phase_stats" do
    belongs_to :batch_run, AskDrive.Batch.BatchRun
    field :phase_name, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :duration_seconds, :integer
    field :items_count, :integer, default: 0
    field :status, :string, default: "completed"

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(stat, attrs) do
    stat
    |> cast(attrs, [
      :batch_run_id,
      :phase_name,
      :started_at,
      :finished_at,
      :duration_seconds,
      :items_count,
      :status
    ])
    |> validate_required([:batch_run_id, :phase_name])
    |> validate_inclusion(:status, ["completed", "failed", "aborted"])
    |> foreign_key_constraint(:batch_run_id)
  end
end
