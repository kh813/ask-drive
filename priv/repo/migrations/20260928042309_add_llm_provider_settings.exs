defmodule AskDrive.Repo.Migrations.AddLlmProviderSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # --- Provider selection (spec 6.2.2) ---
      add :llm_provider, :string, default: "ollama", null: false
      add :embed_provider, :string, default: "ollama", null: false
      add :embedding_dim, :integer, default: 1024, null: false
      add :llm_max_tokens, :integer, default: 4096, null: false
      add :llm_temperature, :float

      # --- Provider credentials and endpoints (spec 6.2.2.1) ---
      add :ollama_host, :string
      add :lmstudio_base_url, :string
      add :openai_api_key, :binary
      add :openai_base_url, :string
      add :anthropic_api_key, :binary
      add :anthropic_base_url, :string
      add :gemini_api_key, :binary
      add :gemini_base_url, :string
    end
  end
end
