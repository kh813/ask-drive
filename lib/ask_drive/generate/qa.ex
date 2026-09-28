defmodule AskDrive.Generate.QA do
  @moduledoc """
  Generates hypothetical question-and-answer pairs from document chunks using local LLM.
  Parses JSON outputs, detects hallucinations, and prevents duplicates.
  """
  alias AskDrive.Documents.Chunk
  alias AskDrive.LLM.{Ollama, Semaphore}

  @system_prompt """
  あなたは社内ナレッジの想定質問回答（QA）を生成するAIアシスタントです。
  与えられた【文書セクション】の内容のみを根拠として、利用者が検索・質問しそうな「質問」とそれに対する明確な「回答」のペアを3〜5件作成してください。

  【制約事項】
  1. 文書本文に記載されていない事実や推測、外部の知識を勝手に追加しないでください。
  2. 質問は自然な疑問文にしてください（例: 「有給休暇の申請期限はいつまでですか？」）。
  3. 回答は過不足なく簡潔で分かりやすい文章にしてください。
  4. 出力は必ず以下のJSON配列形式のみを出力してください。挨拶やコードブロックの説明文は一切不要です。

  [
    {
      "question": "質問文1",
      "answer": "回答文1"
    }
  ]
  """

  @doc """
  Generates QA pairs for a given chunk.
  Returns `{:ok, [%{question: q, answer: a, hallucination_flag: bool}]}` or `{:error, reason}`.
  """
  def generate_for_chunk(%Chunk{} = chunk, model, num_ctx \\ 4096) do
    case AskDrive.Runtime.Mode.check_generation_allowed() do
      :ok ->
        do_generate_for_chunk(chunk, model, num_ctx)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_generate_for_chunk(%Chunk{} = chunk, model, num_ctx) do
    prompt = """
    【文書セクション】
    #{chunk.content}

    上記の内容から想定質問と回答のペアをJSON配列形式で作成してください:
    """

    # Call LLM with semaphore control
    llm_result =
      Semaphore.run(fn ->
        Ollama.generate(model, prompt, system: @system_prompt, num_ctx: num_ctx)
      end)

    case llm_result do
      {:ok, response} ->
        case parse_qa_json(response) do
          {:ok, qa_list} ->
            processed =
              Enum.map(qa_list, fn item ->
                h_flag = check_hallucination(chunk.content, item["answer"])

                %{
                  question: String.trim(item["question"]),
                  answer: String.trim(item["answer"]),
                  hallucination_flag: h_flag
                }
              end)
              |> Enum.filter(fn item -> item.question != "" and item.answer != "" end)

            {:ok, processed}

          {:error, _parse_err} ->
            # Retry 1 time with strict JSON formatting
            retry_generation(chunk, model, num_ctx)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_generation(chunk, model, num_ctx) do
    retry_prompt = """
    【文書セクション】
    #{chunk.content}

    先ほどの出力がJSONとして解析できませんでした。
    必ず厳密なJSON配列形式 `[{"question": "...", "answer": "..."}]` のみを出力してください:
    """

    llm_result =
      Semaphore.run(fn ->
        Ollama.generate(model, retry_prompt, system: @system_prompt, num_ctx: num_ctx)
      end)

    case llm_result do
      {:ok, response} ->
        case parse_qa_json(response) do
          {:ok, qa_list} ->
            processed =
              Enum.map(qa_list, fn item ->
                h_flag = check_hallucination(chunk.content, item["answer"])

                %{
                  question: String.trim(item["question"]),
                  answer: String.trim(item["answer"]),
                  hallucination_flag: h_flag
                }
              end)

            {:ok, processed}

          {:error, parse_err} ->
            {:error, "JSON parse failed after retry: #{inspect(parse_err)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extracts and parses JSON array from LLM text response.
  """
  def parse_qa_json(response) when is_binary(response) do
    cleaned =
      response
      |> String.replace(~r/```json\s*/, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    # Find [ ... ] boundaries
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

  # Simple hallucination check: checks if numbers in answer are present in source chunk
  defp check_hallucination(source_content, answer) do
    numbers_in_answer = Regex.scan(~r/\d+[\.\d]*/, answer) |> List.flatten()

    Enum.any?(numbers_in_answer, fn num ->
      not String.contains?(source_content, num)
    end)
  end
end
