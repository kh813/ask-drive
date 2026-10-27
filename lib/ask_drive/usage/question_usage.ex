defmodule AskDrive.Usage.QuestionUsage do
  @moduledoc """
  One question asked in the chat (spec F-1415): who asked (the platform's user id, 0 for the
  guest), how it was answered, and the tokens answering it used (the query embedding and the
  AI summary). Never the question's text: the 「利用状況」 tab shows how much each person
  uses a desk, not what they asked.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "question_usage" do
    field :user_id, :integer
    field :question_log_id, :integer
    field :tier, :integer
    field :follow_up, :boolean, default: false
    field :tokens, :integer, default: 0
    field :asked_at, :utc_datetime
  end

  @doc false
  def changeset(usage, attrs) do
    usage
    |> cast(attrs, [:user_id, :question_log_id, :tier, :follow_up, :tokens, :asked_at])
    |> validate_required([:user_id, :asked_at])
  end
end
