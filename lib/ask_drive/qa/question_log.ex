defmodule AskDrive.QA.QuestionLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "question_log" do
    field :question, :string
    field :question_embedding, :binary
    field :tier_reached, :integer
    field :candidate_chunk_ids, {:array, :integer}
    field :resolved_at, :utc_datetime
    belongs_to :resolved_qa, AskDrive.QA.QAPair, foreign_key: :resolved_qa_id
    field :asked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :question,
      :question_embedding,
      :tier_reached,
      :candidate_chunk_ids,
      :resolved_at,
      :resolved_qa_id,
      :asked_at
    ])
    |> validate_required([:question, :tier_reached])
    |> validate_inclusion(:tier_reached, [0, 1, 2, 3])
  end
end
