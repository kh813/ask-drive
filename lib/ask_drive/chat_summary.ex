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
  # What is shown is cut at this many characters whatever the model does (and generation is
  # stopped there), so a model that ignores the budget still can't flood the chat.
  @ja_display_cap 300
  @en_display_cap 1_200
  # A reasoning model's hidden thinking isn't shown, but it mustn't run forever either.
  @raw_cap 8_000

  @system_prompt """
  あなたは社内文書の検索アシスタントです。与えられた「抜粋」だけを根拠に、質問と同じ言語で、短く簡潔に答えます。
  抜粋に書かれていないことは推測で補わず、一般論も前置きも付け加えません。
  """

  @doc "Whether chat summaries are switched on in the settings."
  def enabled?(setting \\ Settings.get_setting!()),
    do: Map.get(setting, :chat_summary_enabled, true)

  @doc """
  Generates the summary, reporting progress through `on_event`:

    * `{:answer, text}` — the next piece of the answer (thinking removed, length-capped)
    * `{:thinking, text}` — the next piece of a reasoning model's thinking, which the chat
      shows collapsed rather than in the answer

  Returns `{:ok, %{text: answer, thinking: thinking}}` or `{:error, reason}`.
  """
  def generate(question, chunks, on_event \\ fn _ -> :ok end) when is_list(chunks) do
    setting = Settings.get_setting!()
    {provider, model} = provider_and_model(setting)
    cap = if japanese?(question), do: @ja_display_cap, else: @en_display_cap
    thinks? = reasoning_model?(model)

    opts = [
      setting: setting,
      provider: provider,
      system: @system_prompt,
      timeout: @timeout,
      max_tokens: @max_tokens,
      temperature: 0.2
    ]

    Process.put({__MODULE__, :raw}, "")
    Process.put({__MODULE__, :sent}, %{answer: 0, thinking: 0})

    # Pieces arrive raw; answer and thinking are separated and passed on as they grow.
    filtered = fn piece ->
      raw = Process.get({__MODULE__, :raw}) <> piece
      Process.put({__MODULE__, :raw}, raw)

      visible = visible_text(raw, thinks?, false)
      emit(:thinking, thinking_text(raw, thinks?, false), on_event)
      emit(:answer, String.slice(visible, 0, cap), on_event)

      if String.length(visible) >= cap or String.length(raw) >= @raw_cap, do: :halt, else: :ok
    end

    result = LLM.generate_stream(model, build_prompt(question, chunks, model), opts, filtered)
    raw = Process.get({__MODULE__, :raw}, "")

    case result do
      {:ok, _} ->
        visible = visible_text(raw, thinks?, true)
        shown = String.slice(visible, 0, cap)

        # Whatever was held back (a thinking model that never closed </think>) goes out now
        emit(:answer, shown, on_event)
        truncated? = String.length(visible) > cap
        if truncated?, do: on_event.({:answer, "…"})

        {:ok,
         %{
           text: if(truncated?, do: shown <> "…", else: shown),
           thinking: thinking_text(raw, thinks?, true)
         }}

      error ->
        error
    end
  end

  # Sends the part of `full` not yet sent for this kind of text.
  defp emit(kind, full, on_event) do
    sent = Process.get({__MODULE__, :sent})
    len = String.length(full)

    if len > sent[kind] do
      on_event.({kind, String.slice(full, sent[kind]..-1//1)})
      Process.put({__MODULE__, :sent}, Map.put(sent, kind, len))
    end
  end

  @doc """
  The thinking part of a (possibly partial) output, for the collapsed "思考過程" view.
  Mirrors `visible_text/3`; untagged text from a reasoning model counts as thinking until the
  stream ends without a `</think>`, at which point it turns out to have been the answer.
  """
  def thinking_text(raw, thinks?, done?) do
    cond do
      String.contains?(raw, "</think>") ->
        raw |> String.split("</think>") |> Enum.drop(-1) |> Enum.join() |> strip_open_tag()

      String.contains?(raw, "<think>") ->
        raw |> String.split("<think>", parts: 2) |> List.last() |> String.trim()

      thinks? and not done? ->
        String.trim(raw)

      true ->
        ""
    end
  end

  defp strip_open_tag(text), do: text |> String.replace("<think>", "") |> String.trim()

  @doc """
  The part of a (possibly partial) model output meant for the reader.

  Reasoning models (qwen3, deepseek-r1, …) think before answering. The thinking arrives as
  `<think>…</think>`, or — when the chat template already opened the tag in the prompt — as
  plain text followed by `</think>`, which is why a thinking model's output is held back
  until `</think>` shows up (or the stream ends: `done?`).
  """
  def visible_text(raw, thinks?, done?) do
    cond do
      String.contains?(raw, "</think>") ->
        raw |> String.split("</think>") |> List.last() |> String.trim_leading()

      String.contains?(raw, "<think>") ->
        raw |> String.split("<think>") |> hd() |> String.trim()

      thinks? and not done? ->
        ""

      true ->
        String.trim(raw)
    end
  end

  @doc "Whether a model name belongs to a family that reasons (thinks) before answering."
  def reasoning_model?(model) when is_binary(model) do
    name = String.downcase(model)

    Regex.match?(~r/qwen3|deepseek-r1|qwq|think|magistral|gpt-oss/, name) and
      not String.contains?(name, "instruct")
  end

  def reasoning_model?(_), do: false

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
  def build_prompt(question, chunks, model \\ nil) do
    excerpts =
      chunks
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {chunk, n} ->
        "[#{n}] #{source_label(chunk)}\n" <>
          (chunk.content |> Snippet.display_text() |> String.slice(0, @max_excerpt_chars))
      end)

    prompt =
      if japanese?(question),
        do: ja_prompt(question, excerpts),
        else: en_prompt(question, excerpts)

    # qwen3's own switch for "answer directly, no reasoning" (Ollama's think:false alone did
    # not stop it on the POC machine: the chat showed pages of English reasoning)
    if reasoning_model?(model) and String.contains?(String.downcase(model), "qwen3"),
      do: prompt <> "\n/no_think",
      else: prompt
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
end
