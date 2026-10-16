defmodule AskDrive.Generate.Extraction do
  @moduledoc """
  Extracts structured key-value pairs (dates, monetary amounts, model numbers, identifiers) from text.
  """
  alias AskDrive.LLM
  alias AskDrive.LLM.Semaphore

  @system_prompt """
  あなたは文書から重要項目（日付・金額・数値・型番・担当者など）を抽出するAIです。
  与えられた文書に明確な項目があれば、以下のJSON配列形式で抽出してください。該当がない場合は空配列 `[]` を返してください。

  [
    {
      "key": "項目名 (例: 契約締結日)",
      "value": "値 (例: 2026-04-01)",
      "value_type": "date" または "money" または "number" または "text"
    }
  ]
  """

  @doc """
  Extracts structured items from chunk text.
  """
  def extract(text, model, num_ctx \\ 4096) when is_binary(text) do
    case AskDrive.Runtime.Mode.check_generation_allowed() do
      :ok ->
        prompt = """
        【文書内容】
        #{text}

        上記の文書から重要項目をJSON配列形式で抽出してください:
        """

        Semaphore.run(fn ->
          case LLM.generate(model, prompt, system: @system_prompt, num_ctx: num_ctx) do
            {:ok, response} ->
              case parse_json(response) do
                {:ok, items} -> {:ok, items}
                _ -> {:ok, []}
              end

            {:error, reason} ->
              {:error, reason}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_json(response) do
    cleaned =
      response
      |> String.replace(~r/```json\s*/, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    case Regex.run(~r/\[\s*\{.*\}\s*\]/s, cleaned) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _ -> Jason.decode(cleaned)
        end

      nil ->
        case Jason.decode(cleaned) do
          {:ok, list} when is_list(list) -> {:ok, list}
          error -> error
        end
    end
  end
end
