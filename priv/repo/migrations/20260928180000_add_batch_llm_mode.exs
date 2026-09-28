defmodule AskDrive.Repo.Migrations.AddBatchLlmMode do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Where the nightly batch generates QA (spec 6.8 F-821): "local" uses llm_provider /
      # batch_model (Ollama, LM Studio), "cloud" uses cloud_llm_provider / cloud_llm_model.
      # Both sets are kept, so switching back and forth doesn't lose either configuration.
      add :batch_llm_mode, :string, default: "local", null: false
      add :cloud_llm_provider, :string, default: "gemini"
      add :cloud_llm_model, :string
    end
  end
end
