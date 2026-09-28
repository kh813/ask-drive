defmodule AskDrive.Repo.Migrations.AddChatSummaryEnabled do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Live AI summary of the retrieved excerpts in chat, with citations (spec 6.4.4).
      add :chat_summary_enabled, :boolean, default: true, null: false
    end
  end
end
