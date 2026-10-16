defmodule AskDrive.Generate.Summary do
  @moduledoc """
  Generates document and section summaries using LLM for overview and quick inspection.
  (Rule: Summaries are not used as ground-truth evidence for QA retrieval).
  """
  alias AskDrive.LLM
  alias AskDrive.LLM.Semaphore

  @system_prompt """
  あなたは社内ドキュメントの要約を作成するAIアシスタントです。
  与えられた文書の内容から、要点を簡潔にまとめた日本語の要約文を作成してください。
  箇条書きまたは短い段落で、重要な事実のみを記述してください。
  """

  @doc """
  Generates a summary for document or section text.
  """
  def generate(text, model, num_ctx \\ 4096) when is_binary(text) do
    case AskDrive.Runtime.Mode.check_generation_allowed() do
      :ok ->
        prompt = """
        【文書内容】
        #{text}

        上記の要点を簡潔に要約してください:
        """

        Semaphore.run(fn ->
          case LLM.generate(model, prompt, system: @system_prompt, num_ctx: num_ctx) do
            {:ok, response} ->
              {:ok, String.trim(response)}

            {:error, reason} ->
              {:error, reason}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
