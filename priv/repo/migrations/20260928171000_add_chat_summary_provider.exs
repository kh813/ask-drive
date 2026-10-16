defmodule AskDrive.Repo.Migrations.AddChatSummaryProvider do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Chat answers may use a different provider than the nightly batch: local Ollama for
      # the slow unattended QA generation, a fast cloud model (e.g. Gemini) for users waiting
      # on an answer (spec F-415). nil = same as llm_provider / batch_model.
      add :chat_summary_provider, :string
      add :chat_summary_model, :string
    end
  end
end
