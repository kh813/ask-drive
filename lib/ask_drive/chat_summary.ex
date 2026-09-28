defmodule AskDrive.ChatSummary do
  @moduledoc """
  Live AI summary for a chat answer (spec 6.4.4).

  Given the question and the excerpts retrieval found, asks the chat summary provider
  (`chat_summary_provider`, defaulting to the batch's `llm_provider`: Ollama during the POC;
  a fast cloud API such as Gemini in production, while the nightly batch stays local)
  for a short answer grounded only in those excerpts, citing them as [1], [2], … so the chat
  can link each claim to its source. The excerpts themselves are always shown too: the
  summary is a reading aid, the excerpts are the evidence.
  """
  alias AskDrive.{LLM, Settings, Snippet}

  @max_excerpt_chars 1_200
  @timeout 120_000

  # Answers were far too long for a chat reply. The prompt asks for a budget and max_tokens
  # (Ollama: num_predict) enforces a hard stop a little above it.
  @ja_chars 250
  @en_words 150
  @max_tokens 450

  @system_prompt """
  あなたは社内文書の検索アシスタントです。与えられた「抜粋」だけを根拠に、質問と同じ言語で、短く簡潔に答えます。
  抜粋に書かれていないことは推測で補わず、一般論も前置きも付け加えません。
  """

  @doc "Whether chat summaries are switched on in the settings."
  def enabled?(setting \\ Settings.get_setting!()),
    do: Map.get(setting, :chat_summary_enabled, true)

  @doc """
  Generates the summary, calling `on_delta.(text)` as it is written.
  Returns `{:ok, text}` or `{:error, reason}`.
  """
  def generate(question, chunks, on_delta \\ fn _ -> :ok end) when is_list(chunks) do
    setting = Settings.get_setting!()
    {provider, model} = provider_and_model(setting)

    opts = [
      setting: setting,
      provider: provider,
      system: @system_prompt,
      timeout: @timeout,
      max_tokens: @max_tokens,
      temperature: 0.2
    ]

    model
    |> LLM.generate_stream(build_prompt(question, chunks), opts, on_delta)
    |> case do
      {:ok, text} -> {:ok, strip_thinking(text)}
      error -> error
    end
  end

  @doc """
  Provider and model for chat summaries: `chat_summary_provider` / `chat_summary_model`
  when set (e.g. Gemini for fast, accurate answers), otherwise the nightly batch's
  generation provider / model (local or cloud per `batch_llm_mode`, spec F-415 / F-821).
  """
  def provider_and_model(setting) do
    provider =
      case setting.chat_summary_provider do
        p when is_binary(p) and p != "" -> p
        _ -> LLM.generation_provider(setting)
      end

    model =
      case setting.chat_summary_model do
        m when is_binary(m) and m != "" -> m
        _ -> LLM.generation_model(setting)
      end

    {provider, model}
  end

  @doc "The prompt: the question, numbered excerpts with their source, and the rules."
  def build_prompt(question, chunks) do
    excerpts =
      chunks
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {chunk, n} ->
        "[#{n}] #{source_label(chunk)}\n" <>
          (chunk.content |> Snippet.display_text() |> String.slice(0, @max_excerpt_chars))
      end)

    if japanese?(question), do: ja_prompt(question, excerpts), else: en_prompt(question, excerpts)
  end

  defp ja_prompt(question, excerpts) do
    """
    質問: #{question}

    抜粋:
    #{excerpts}

    指示:
    - 必ず日本語で答えてください。
    - #{@ja_chars}字以内で答えてください。要点が複数あれば3点以内の箇条書きにしてください。前置き・まとめ・繰り返しは不要です。
    - 抜粋に書かれている内容だけを使ってください。
    - 根拠にした抜粋の番号を、該当する文の末尾に [1] のように付けてください。
    - 抜粋から答えられない場合は「資料からは確認できませんでした。」とだけ答えてください。
    """
  end

  defp en_prompt(question, excerpts) do
    """
    Question: #{question}

    Excerpts:
    #{excerpts}

    Instructions:
    - Answer in the same language as the question.
    - Keep it under #{@en_words} words; use at most 3 bullet points if there are several points. No preamble or recap.
    - Use only what the excerpts say.
    - Cite the excerpt(s) you rely on at the end of the sentence, like [1].
    - If the excerpts don't answer the question, reply only: "The documents don't cover this."
    """
  end

  @doc "Whether the question is written in Japanese (contains kana or kanji)."
  def japanese?(text) when is_binary(text),
    do: Regex.match?(~r/[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}]/u, text)

  @doc "\"doc name p.N\" for a chunk."
  def source_label(chunk) do
    name = (chunk.document && chunk.document.name) || "ドキュメント"
    if chunk.page, do: "#{name} p.#{chunk.page}", else: name
  end

  # Reasoning models may still emit a <think>…</think> preamble; readers only want the answer.
  defp strip_thinking(text) do
    text
    |> String.replace(~r/<think>.*?<\/think>/su, "")
    |> String.trim()
  end
end
