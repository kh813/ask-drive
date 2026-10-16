defmodule AskDrive.Repo.Migrations.CreateChatHistory do
  use Ecto.Migration

  def change do
    # Each signed-in user's questions and the answers they got, in the desk's own database
    # (spec F-430). user_id is the platform's users.id (another database: no foreign key).
    create table(:chat_history) do
      add :user_id, :integer, null: false
      add :question, :text, null: false
      add :tier, :integer, null: false
      add :answer, :text
      add :summary, :text
      add :qa_pair_id, :integer
      add :chunk_ids, {:array, :integer}
      # what the excerpts were (document, page, link), for when they were re-indexed since
      add :sources, {:array, :map}
      add :index_empty, :boolean, default: false, null: false
      add :asked_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:chat_history, [:user_id, :asked_at])
  end
end
