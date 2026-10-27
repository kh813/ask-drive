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
  require Logger

  use Gettext, backend: AskDriveWeb.Gettext
  alias AskDrive.{LLM, Settings, Snippet}

  @max_excerpt_chars 1_200
  @timeout 120_000

  # A reasoning model's hidden thinking isn't shown, but it mustn't run forever either.
  @raw_cap 8_000

  # Answer styles (spec F-432), picked in the admin settings (`chat_answer_style`). Each sets
  # the tone and the length: the prompt asks for a budget (ja_chars / en_words), max_tokens
  # (Ollama: num_predict) enforces a hard stop a little above it, and what is shown is cut at
  # ja_cap / en_cap characters whatever the model does (generation is stopped there), so a
  # model that ignores the budget still can't flood the chat. "concise" keeps the POC's short
  # answers, which small local models follow best; the others suit a cloud model (Gemini, …).
  # Whatever the style, the answer rests only on the excerpts, cites them as [n] and says so
  # when they don't answer the question (F-416): those rules are in every prompt.
  @styles %{
    "concise" => %{
      label: gettext_noop("Concise (no generalities or preamble)"),
      description:
        gettext_noop(
          "Answers with the key points only, in up to 250 characters (at most 3 bullet points). Suited to small local models."
        ),
      ja_chars: 250,
      en_words: 150,
      max_tokens: 450,
      ja_cap: 300,
      en_cap: 1_200,
      system: """
      あなたは社内文書の検索アシスタントです。与えられた「抜粋」だけを根拠に、質問と同じ言語で、短く簡潔に答えます。
      抜粋に書かれていないことは推測で補わず、一般論も前置きも付け加えません。
      """,
      ja_rules: """
      - __CHARS__字以内で答えてください。要点が複数あれば3点以内の箇条書きにしてください。前置き・まとめ・繰り返しは不要です。
      """,
      en_rules: """
      - Keep it under __WORDS__ words; use at most 3 bullet points if there are several points. No preamble or recap.
      """
    },
    "conversational" => %{
      label: gettext_noop("Conversational (explained politely, as to a colleague)"),
      description:
        gettext_noop(
          "Answers in a polite, natural tone, as if talking to a colleague: the conclusion, then the key points as bullets, then a one-line note (up to 500 characters)."
        ),
      ja_chars: 500,
      en_words: 300,
      max_tokens: 900,
      ja_cap: 600,
      en_cap: 2_400,
      system: """
      あなたは社内文書の検索アシスタントです。社内の同僚に説明するように、丁寧で自然な口調で答えます。
      与えられた「抜粋」だけを根拠に、質問と同じ言語で答え、抜粋に書かれていないことは推測や一般論で補いません。
      """,
      ja_rules: """
      - 同僚に話しかけるように、丁寧で自然な口調（です・ます調）で、__CHARS__字以内で答えてください。
      - 最初の1〜2文で質問に答え、要点が複数あれば5点以内の箇条書きで示してください。抜粋に注意点や問い合わせ先があれば、最後に一言添えてください。
      - 挨拶や、質問の言い直しは不要です。
      """,
      en_rules: """
      - Answer in a polite, natural tone, as if explaining to a colleague, in under __WORDS__ words.
      - Answer the question in the first sentence or two, then list the key points (at most 5 bullets) if there are several. If the excerpts mention caveats or whom to contact, add a short closing note.
      - No greetings, and don't restate the question.
      """
    },
    "detailed" => %{
      label: gettext_noop("Detailed (conditions, steps and exceptions)"),
      description:
        gettext_noop(
          "After the conclusion, sets out the steps, conditions, exceptions and deadlines in the excerpts as numbered lists or bullets (up to 800 characters)."
        ),
      ja_chars: 800,
      en_words: 450,
      max_tokens: 1_400,
      ja_cap: 1_000,
      en_cap: 3_600,
      system: """
      あなたは社内文書の検索アシスタントです。与えられた「抜粋」だけを根拠に、質問と同じ言語で、丁寧に漏れなく整理して答えます。
      抜粋に書かれていないことは推測や一般論で補いません。
      """,
      ja_rules: """
      - __CHARS__字以内で、です・ます調で答えてください。
      - 最初に結論を1文で述べ、続けて抜粋にある手順は番号付きリスト、条件・例外・期限・注意点は箇条書きで整理してください。
      - 抜粋同士で内容が食い違う場合は、両方を示し、食い違っていることを書いてください。
      """,
      en_rules: """
      - Keep it under __WORDS__ words.
      - State the conclusion in one sentence first, then lay out the steps from the excerpts as a numbered list and the conditions, exceptions, deadlines and caveats as bullet points.
      - If the excerpts disagree, give both and say that they disagree.
      """
    },
    "plain" => %{
      label: gettext_noop("Plain (for new members)"),
      description:
        gettext_noop(
          "Explains jargon and abbreviations in words that someone who has just joined can follow (up to 500 characters)."
        ),
      ja_chars: 500,
      en_words: 300,
      max_tokens: 900,
      ja_cap: 600,
      en_cap: 2_400,
      system: """
      あなたは社内文書の検索アシスタントです。社内に来たばかりの人にも分かるように、やさしい言葉で丁寧に答えます。
      与えられた「抜粋」だけを根拠に、質問と同じ言語で答え、抜粋に書かれていないことは推測や一般論で補いません。
      """,
      ja_rules: """
      - 配属されたばかりの人にも分かるように、やさしい言葉（です・ます調）で、__CHARS__字以内で答えてください。
      - 専門用語や略語は、抜粋にある説明を使って言い換えてください。抜粋に説明が無い用語の意味は付け加えないでください。
      - 最初に結論を1文で述べ、要点が複数あれば5点以内の箇条書きにしてください。
      """,
      en_rules: """
      - Use plain, simple words that someone new to the company would understand, in under __WORDS__ words.
      - Explain jargon and abbreviations using what the excerpts say about them; don't add meanings the excerpts don't give.
      - State the conclusion in one sentence first, then list the key points (at most 5 bullets) if there are several.
      """
    }
  }
  @style_order ~w(concise conversational detailed plain)
  @default_style "concise"

  @doc "The answer styles as `{label, value}` pairs for a select, in display order (F-432)."
  def style_options,
    do: Enum.map(@style_order, &{Gettext.gettext(AskDriveWeb.Gettext, @styles[&1].label), &1})

  @doc "A one-line explanation of an answer style, for the admin settings."
  def style_description(style),
    do: Gettext.gettext(AskDriveWeb.Gettext, style_config(style).description)

  @doc "The answer style the settings pick; an unknown or missing one falls back to concise."
  def style(setting) do
    case Map.get(setting, :chat_answer_style) do
      style when is_map_key(@styles, style) -> style
      _ -> @default_style
    end
  end

  defp style_config(style), do: Map.get(@styles, style, @styles[@default_style])

  @doc """
  How many excerpts Tier 2 finds (spec F-434): up to 8 for a summary on a cloud API, 4 on the
  local LLM (Ollama's context, 4,096 tokens by default, holds about that many with the
  instructions; more and the start of the prompt is cut off), and 3 without a summary (the
  excerpts alone are read by the person).
  """
  def excerpt_limit(setting \\ Settings.get_setting!()) do
    cond do
      not enabled?(setting) -> 3
      LLM.local?(elem(provider_and_model(setting), 0)) -> 4
      true -> 8
    end
  end

  @doc "Whether chat summaries are switched on in the settings."
  def enabled?(setting \\ Settings.get_setting!()),
    do: Map.get(setting, :chat_summary_enabled, true)

  @doc """
  Generates the summary, reporting progress through `on_event`:

    * `{:answer, text}` — the next piece of the answer (thinking removed, length-capped)
    * `{:thinking, text}` — the next piece of a reasoning model's thinking, which the chat
      shows collapsed rather than in the answer

  Returns `{:ok, %{text: answer, thinking: thinking}}` or `{:error, reason}`.

  A follow-up in a chat thread (F-431) passes the thread's earlier exchanges as `context:`
  (`[%{question: q, answer: a}]`, oldest first): the prompt shows them, so the question is
  read as their continuation.
  """
  def generate(question, chunks, on_event \\ fn _ -> :ok end, opts \\ []) when is_list(chunks) do
    context = Keyword.get(opts, :context, [])
    setting = Settings.get_setting!()
    {provider, model} = provider_and_model(setting)
    model = available_model(provider, model, setting)
    style = style(setting)
    config = style_config(style)
    ja? = japanese?(question)
    cap = if ja?, do: config.ja_cap, else: config.en_cap
    thinks? = reasoning_model?(model)

    reset_state()

    # Reasoning models: ask Ollama to return the thinking in its own field (think: true), so
    # the answer needs no tag guessing. Thinking tokens count against num_predict, so the
    # answer is capped by characters (below) rather than tokens for these models.
    opts =
      [
        setting: setting,
        provider: provider,
        system: config.system,
        timeout: @timeout,
        max_tokens: if(thinks?, do: nil, else: config.max_tokens),
        temperature: 0.2,
        think: thinks?,
        on_thinking: fn thought ->
          field = Process.get({__MODULE__, :field_thinking}) <> thought
          Process.put({__MODULE__, :field_thinking}, field)
          emit(:thinking, field, on_event)
          if String.length(field) >= @raw_cap, do: :halt, else: :ok
        end
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    # Answer pieces: tags are still honoured for models/versions that inline the thinking.
    filtered = fn piece ->
      raw = Process.get({__MODULE__, :raw}) <> piece
      Process.put({__MODULE__, :raw}, raw)
      inline? = thinks? and Process.get({__MODULE__, :field_thinking}) == ""

      visible = visible_text(raw, inline?, false)
      if inline?, do: emit(:thinking, thinking_text(raw, true, false), on_event)
      emit(:answer, String.slice(visible, 0, cap), on_event)

      if String.length(visible) >= cap or String.length(raw) >= @raw_cap, do: :halt, else: :ok
    end

    result =
      LLM.generate_stream(
        model,
        build_prompt(question, chunks, model, context, style),
        opts,
        filtered
      )

    with {:ok, _} <- result do
      raw = Process.get({__MODULE__, :raw}, "")
      field_thinking = Process.get({__MODULE__, :field_thinking}, "")
      inline? = thinks? and field_thinking == ""

      answer = visible_text(raw, inline?, true)

      thinking =
        [field_thinking, if(inline?, do: thinking_text(raw, true, true), else: "")]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      # The model thought "out loud" without marking where the answer starts, or answered a
      # Japanese question in another language: ask once more for just the conclusion.
      ambiguous? = inline? and not String.contains?(raw, "</think>")
      wrong_language? = ja? and answer != "" and not mostly_japanese?(answer)

      if ambiguous? or wrong_language? do
        notes = if ambiguous?, do: raw, else: Enum.join([thinking, answer], "\n")

        finalize(question, chunks, notes, %{
          provider: provider,
          model: model,
          setting: setting,
          style: style,
          cap: cap,
          on_event: on_event,
          context: context
        })
      else
        answer = tidy(answer, length(chunks))
        emit(:answer, String.slice(answer, 0, cap), on_event)
        {:ok, %{text: cap_text(answer, cap, on_event), thinking: thinking}}
      end
    end
  end

  # Second pass: the first output (thinking and/or a wrong-language answer) becomes notes, and
  # the model is asked for the conclusion only, in the question's language, within budget.
  defp finalize(question, chunks, notes, run) do
    %{model: model, style: style, cap: cap, on_event: on_event} = run
    config = style_config(style)
    on_event.(:answer_reset)
    Process.put({__MODULE__, :raw}, "")
    Process.put({__MODULE__, :sent}, %{answer: 0, thinking: 0})

    opts = [
      setting: run.setting,
      provider: run.provider,
      system: config.system,
      timeout: @timeout,
      max_tokens: config.max_tokens,
      temperature: 0.2,
      think: false
    ]

    prompt = finalize_prompt(question, chunks, notes, model, run.context, style)

    stream = fn piece ->
      raw = Process.get({__MODULE__, :raw}) <> piece
      Process.put({__MODULE__, :raw}, raw)
      visible = visible_text(raw, false, false)
      emit(:answer, String.slice(visible, 0, cap), on_event)
      if String.length(visible) >= cap, do: :halt, else: :ok
    end

    with {:ok, _} <- LLM.generate_stream(model, prompt, opts, stream) do
      answer =
        Process.get({__MODULE__, :raw}, "") |> visible_text(false, true) |> tidy(length(chunks))

      emit(:answer, String.slice(answer, 0, cap), on_event)
      {:ok, %{text: cap_text(answer, cap, on_event), thinking: String.trim(notes)}}
    end
  end

  # A chat model that isn't pulled (pulling is the platform administrator's, F-838) would
  # fail every summary: answer with the batch model meanwhile.
  defp available_model("ollama", model, setting) do
    alias AskDrive.LLM.OllamaModels

    with {:ok, names} <- OllamaModels.installed(setting),
         false <- OllamaModels.installed?(model, names) do
      fallback = LLM.generation_model(setting)

      if LLM.generation_provider(setting) == "ollama" and is_binary(fallback) and
           OllamaModels.installed?(fallback, names) do
        Logger.info("ChatSummary: #{model} not pulled; using #{fallback}")
        fallback
      else
        model
      end
    else
      _ -> model
    end
  end

  defp available_model(_provider, model, _setting), do: model

  @doc "The prompt for the second pass: excerpts, the first attempt as notes, the rules."
  def finalize_prompt(
        question,
        chunks,
        notes,
        model \\ nil,
        context \\ [],
        style \\ @default_style
      ) do
    base = build_prompt(question, chunks, nil, context, style)
    notes = (notes || "") |> String.trim() |> String.slice(-3_000, 3_000)

    intro =
      if japanese?(question),
        do:
          "\n参考: 以下は、この質問について AI が検討したメモです。メモの結論を、上の指示に従って日本語で答えてください。メモの言い回しや検討過程は書かないでください。\n",
        else:
          "\nFor reference, notes from a first attempt follow. Give only their conclusion, following the instructions above.\n"

    prompt = base <> intro <> "---\n" <> notes <> "\n---\n"

    if reasoning_model?(model) and String.contains?(String.downcase(model), "qwen3"),
      do: prompt <> "/no_think",
      else: prompt
  end

  @not_covered ["資料からは確認できませんでした", "The documents don't cover this"]

  @doc """
  Cleans up what a model got wrong in an answer (spec F-435): the "not covered" line added
  after an answer (it is meant to be the whole reply, when there is no answer), and citations
  of excerpts that don't exist (`[4]` with three excerpts).
  """
  def tidy(answer, excerpts) do
    lines = String.split(answer, "\n")
    kept = Enum.reject(lines, &not_covered_line?/1)

    answer =
      if Enum.any?(kept, &(String.trim(&1) != "")),
        do: kept |> Enum.join("\n") |> String.trim(),
        else: answer

    Regex.replace(~r/ ?\[(\d+(?:\s*,\s*\d+)*)\]/u, answer, fn whole, numbers ->
      valid =
        numbers
        |> String.split(",")
        |> Enum.map(&String.to_integer(String.trim(&1)))
        |> Enum.filter(&(&1 in 1..max(excerpts, 1)//1 and excerpts > 0))

      cond do
        length(valid) == length(String.split(numbers, ",")) -> whole
        valid == [] -> ""
        true -> String.replace(whole, "[" <> numbers <> "]", "[#{Enum.join(valid, ", ")}]")
      end
    end)
  end

  # a line that is only the "not covered" reply (maybe as a bullet, or in quotes)
  defp not_covered_line?(line) do
    text =
      line
      |> String.trim()
      |> String.trim_leading("-")
      |> String.trim_leading("・")
      |> String.trim()
      |> String.trim("「")
      |> String.trim("」")
      |> String.trim("\"")
      |> String.trim_trailing("。")
      |> String.trim_trailing(".")
      |> String.trim()

    text in @not_covered
  end

  defp cap_text(answer, cap, on_event) do
    if String.length(answer) > cap do
      on_event.({:answer, "…"})
      String.slice(answer, 0, cap) <> "…"
    else
      answer
    end
  end

  defp reset_state do
    Process.put({__MODULE__, :raw}, "")
    Process.put({__MODULE__, :field_thinking}, "")
    Process.put({__MODULE__, :sent}, %{answer: 0, thinking: 0})
  end

  @doc "Whether at least a quarter of the letters are kana/kanji (an answer in Japanese)."
  def mostly_japanese?(text) do
    letters = Regex.scan(~r/[\p{L}]/u, text) |> length()
    ja = Regex.scan(~r/[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}]/u, text) |> length()
    letters == 0 or ja / letters >= 0.25
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
  def build_prompt(question, chunks, model \\ nil, context \\ [], style \\ @default_style) do
    excerpts =
      chunks
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {chunk, n} ->
        "[#{n}] #{source_label(chunk)}\n" <>
          (chunk.content |> Snippet.display_text() |> String.slice(0, @max_excerpt_chars))
      end)

    prompt =
      if japanese?(question),
        do: ja_context(context) <> ja_prompt(question, excerpts, style_config(style)),
        else: en_context(context) <> en_prompt(question, excerpts, style_config(style))

    # qwen3's own switch for "answer directly, no reasoning" (Ollama's think:false alone did
    # not stop it on the POC machine: the chat showed pages of English reasoning)
    if reasoning_model?(model) and String.contains?(String.downcase(model), "qwen3"),
      do: prompt <> "\n/no_think",
      else: prompt
  end

  # the thread so far (F-431): the last few exchanges, each kept short
  @context_turns 3
  @context_answer_chars 400

  defp ja_context([]), do: ""

  defp ja_context(context) do
    turns =
      context
      |> Enum.take(-@context_turns)
      |> Enum.map_join("\n", fn turn ->
        "質問: #{turn.question}" <>
          if(turn[:answer] in [nil, ""],
            do: "",
            else: "\n回答: #{String.slice(turn.answer, 0, @context_answer_chars)}"
          )
      end)

    "これまでのやり取り（次の質問は、このやり取りの続きです。「それ」などはこの内容を指します）:\n#{turns}\n\n"
  end

  defp en_context([]), do: ""

  defp en_context(context) do
    turns =
      context
      |> Enum.take(-@context_turns)
      |> Enum.map_join("\n", fn turn ->
        "Question: #{turn.question}" <>
          if(turn[:answer] in [nil, ""],
            do: "",
            else: "\nAnswer: #{String.slice(turn.answer, 0, @context_answer_chars)}"
          )
      end)

    "The conversation so far (the next question continues it; words like \"it\" refer to it):\n#{turns}\n\n"
  end

  defp ja_prompt(question, excerpts, config) do
    """
    質問: #{question}

    抜粋:
    #{excerpts}

    指示:
    - 必ず日本語で答えてください。
    #{style_rules(config.ja_rules, "__CHARS__", config.ja_chars)}
    - 抜粋に書かれている内容だけを使ってください。
    - 質問の名前・事例などが抜粋の規則や条件に合うかを尋ねられたら、その規則を当てはめて判断し、どの規則に合う（合わない）かを示してください。抜粋にその名前・事例そのものが書かれていなくても構いません。
    - 根拠にした抜粋の番号を、該当する文の末尾に [1] のように付けてください。
    - 抜粋に関係する記述が無く答えられない場合だけ、「資料からは確認できませんでした。」とだけ答えてください。
    """
  end

  defp en_prompt(question, excerpts, config) do
    """
    Question: #{question}

    Excerpts:
    #{excerpts}

    Instructions:
    - Answer in the same language as the question.
    #{style_rules(config.en_rules, "__WORDS__", config.en_words)}
    - Use only what the excerpts say.
    - If asked whether a name, case or example in the question meets a rule or condition in the excerpts, apply that rule to it and say which rule it meets or breaks, even though the excerpts don't mention that name or case itself.
    - Cite the excerpt(s) you rely on at the end of the sentence, like [1].
    - Only if nothing in the excerpts bears on the question, reply only: "The documents don't cover this."
    """
  end

  # the style's own lines of the instructions, with its length budget filled in
  defp style_rules(rules, placeholder, budget),
    do: rules |> String.replace(placeholder, to_string(budget)) |> String.trim_trailing()

  @doc "Whether the question is written in Japanese (contains kana or kanji)."
  def japanese?(text) when is_binary(text),
    do: Regex.match?(~r/[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}]/u, text)

  @doc "\"doc name p.N\" for a chunk."
  def source_label(chunk) do
    name = (chunk.document && chunk.document.name) || "ドキュメント"
    if chunk.page, do: "#{name} p.#{chunk.page}", else: name
  end
end
