defmodule AskDrive.Repo.Migrations.ChatHistoryThreads do
  use Ecto.Migration

  def change do
    # Chat threads (spec F-431): a question and its follow-ups share a key. Entries from
    # before threads each become a thread of their own.
    alter table(:chat_history) do
      add :thread_key, :string
    end

    execute "UPDATE chat_history SET thread_key = 'entry-' || id WHERE thread_key IS NULL", ""

    create index(:chat_history, [:user_id, :thread_key])
  end
end
