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

    # a follow-up's log: the thread's questions joined (not counted in 「よくある質問」, F-1415)
    field :follow_up, :boolean, default: false
    # the asker pressed 「解決した」 under the answer, or asked a follow-up to it (F-433);
    # set by QA.mark_solved/2 and QA.mark_followed_up/1, never cast
    field :user_solved_at, :utc_datetime
    field :followed_up_at, :utc_datetime

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
      :asked_at,
      :follow_up
    ])
    |> validate_required([:question, :tier_reached])
    |> validate_inclusion(:tier_reached, [0, 1, 2, 3])
  end
end
