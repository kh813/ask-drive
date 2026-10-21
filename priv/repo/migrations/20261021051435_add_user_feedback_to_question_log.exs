defmodule AskDrive.Repo.Migrations.AddUserFeedbackToQuestionLog do
  use Ecto.Migration

  # what the asker said of an answer (F-433): 「解決した」, or a follow-up to it
  def change do
    alter table(:question_log) do
      add :user_solved_at, :utc_datetime
      add :followed_up_at, :utc_datetime
    end
  end
end
