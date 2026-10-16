defmodule AskDrive.ChatHistory.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_history" do
    field :user_id, :integer
    # the thread it belongs to: a question and its follow-ups share it (F-431)
    field :thread_key, :string
    field :question, :string
    field :tier, :integer
    field :answer, :string
    field :summary, :string
    field :qa_pair_id, :integer
    field :chunk_ids, {:array, :integer}, default: []
    field :sources, {:array, :map}, default: []
    field :index_empty, :boolean, default: false
    field :asked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :question,
      :thread_key,
      :tier,
      :answer,
      :summary,
      :qa_pair_id,
      :chunk_ids,
      :sources,
      :index_empty,
      :asked_at
    ])
    |> validate_required([:question, :tier, :asked_at])
    |> validate_inclusion(:tier, [0, 1, 2, 3])
  end
end
