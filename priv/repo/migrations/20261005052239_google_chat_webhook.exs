defmodule AskDrive.Repo.Migrations.GoogleChatWebhook do
  use Ecto.Migration

  def change do
    # Google Chat incoming webhook for update notices (spec F-1507, platform row). The URL
    # carries its key and token, so it is stored encrypted like the other secrets.
    alter table(:settings) do
      add :google_chat_webhook_url, :binary
    end
  end
end
