defmodule AskDrive.QA.AnswerCache do
  use Ecto.Schema
  import Ecto.Changeset

  schema "answer_cache" do
    belongs_to :qa_pair, AskDrive.QA.QAPair
    field :normalized_question, :string
    field :hit_count, :integer, default: 1
    field :last_hit_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(cache, attrs) do
    cache
    |> cast(attrs, [:qa_pair_id, :normalized_question, :hit_count, :last_hit_at])
    |> validate_required([:qa_pair_id, :normalized_question])
    |> unique_constraint(:normalized_question)
    |> foreign_key_constraint(:qa_pair_id)
  end
end
