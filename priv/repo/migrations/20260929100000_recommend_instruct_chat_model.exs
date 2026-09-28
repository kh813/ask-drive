defmodule AskDrive.Repo.Migrations.RecommendInstructChatModel do
  use Ecto.Migration

  # Chat summaries on a reasoning model (qwen3:4b) showed its thinking and answered in
  # English; the non-thinking instruct build of the same size behaves (spec F-426). Switch
  # installations whose chat summary still runs on local Ollama with no model of its own.
  # The model is pulled by the app at boot (F-827); until then the summary falls back to the
  # batch model.
  def up do
    execute """
    UPDATE settings
    SET chat_summary_model = 'qwen3:4b-instruct-2507-q4_K_M'
    WHERE (chat_summary_model IS NULL OR chat_summary_model = '')
      AND (chat_summary_provider IS NULL OR chat_summary_provider = '' OR chat_summary_provider = 'ollama')
      AND batch_llm_mode = 'local'
      AND llm_provider = 'ollama'
    """
  end

  def down do
    execute """
    UPDATE settings SET chat_summary_model = NULL
    WHERE chat_summary_model = 'qwen3:4b-instruct-2507-q4_K_M'
    """
  end
end
