defmodule AskDrive.Repo.Migrations.AddChatAnswerStyle do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # How the chat summary answers (spec F-432): "concise" (the POC's short answers),
      # "conversational", "detailed" or "plain".
      add :chat_answer_style, :string, default: "concise", null: false
    end
  end
end
