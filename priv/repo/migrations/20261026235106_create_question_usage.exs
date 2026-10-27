defmodule AskDrive.Repo.Migrations.CreateQuestionUsage do
  use Ecto.Migration

  def change do
    # One row per question asked in the chat, for the 「利用状況」 tab (spec F-1415, F-1416):
    # who asked and the tokens answering it used. Never the question's text, so who asked
    # what can't be read from it. Kept for 90 days, like the API usage logs.
    create table(:question_usage) do
      # the platform's users.id; 0 is the guest (sign-in off)
      add :user_id, :integer, null: false
      add :question_log_id, :integer
      add :tier, :integer
      add :follow_up, :boolean, null: false, default: false
      add :tokens, :integer, null: false, default: 0
      add :asked_at, :utc_datetime, null: false
    end

    create index(:question_usage, [:asked_at])
    create index(:question_usage, [:user_id, :asked_at])

    alter table(:question_log) do
      # a follow-up's log is the thread's questions joined, not a question to count as asked
      # again in 「よくある質問」
      add :follow_up, :boolean, null: false, default: false
    end
  end
end
