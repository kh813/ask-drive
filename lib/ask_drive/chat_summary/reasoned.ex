defmodule AskDrive.ChatSummary.Reasoned do
  @moduledoc """
  Answers that need thinking (spec F-436), with a cloud model only: a question asking whether
  something follows the rules ("この共有ドライブ名は命名規則に沿っていますか？"), or one whose
  wording hides another aim ("Adobe Acrobat を使いたい" → to edit PDFs, where a free app on
  the allowed list may also do).

  `plan/5` asks the model first, briefly and without thinking, how to answer: `:direct` (the
  excerpts answer it as they are, as for "USBメモリを使っていいですか": the summary is made as
  before) or reasoned, with what the person is likely after and search words for it. A
  reasoned answer is then given more to go on (`sources/3`): the whole documents the excerpts
  and those searches found, as far as they fit, so a rule is read with its purpose; and the
  model thinks before answering (`prompt/5`).

  The excerpts shown keep their numbers [1]…[n]; what else the model was given is numbered on
  from n+1, and those it cites are added to the sources shown (`renumber/3`).
  """
  require Logger

  alias AskDrive.Documents.Chunk
  alias AskDrive.{LLM, Repo, Retrieval, Snippet}
  import Ecto.Query, warn: false

  # how much document text a reasoned answer gets: whole documents up to this many
  # characters each, all of them together up to the total
  @doc_chars 20_000
  @total_chars 40_000
  @max_queries 3
  @per_query 4
  @plan_timeout 15_000
  @embed_timeout 10_000

  @doc """
  How to answer `question` given the excerpts `chunks`: `:direct`, or
  `{:reasoned, intent, queries}`. Anything unexpected (an error, a reply that isn't the JSON
  asked for) answers `:direct`, as before.
  """
  def plan(question, chunks, setting, provider, model) do
    case LLM.generate(model, plan_prompt(question, chunks),
           setting: setting,
           provider: provider,
           purpose: "chat_plan",
           think: false,
           max_tokens: 400,
           temperature: 0.0,
           timeout: @plan_timeout
         ) do
      {:ok, text} ->
        parse_plan(text)

      other ->
        Logger.info("ChatSummary: no plan (#{inspect(other)}); answering directly")
        :direct
    end
  end

  @doc false
  def plan_prompt(question, chunks) do
    excerpts =
      chunks
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {chunk, n} ->
        "[#{n}] #{name(chunk)}: " <>
          (chunk.content
           |> Snippet.display_text()
           |> String.replace(~r/\s+/u, " ")
           |> String.slice(0, 160))
      end)

    """
    社内の問い合わせ窓口に届いた質問の、答え方を決めてください。

    質問: #{question}

    検索で見つかった資料（冒頭のみ）:
    #{excerpts}

    答え方:
    - "direct": 資料に、質問への答え（してよいか・いけないか、手順、期限、問い合わせ先など）がそのまま書かれていて、一問一答で答えられる。
    - "reasoned": 質問の名前・事例・計画が規則や方針に沿っているかの確認を求めている。または、質問の文面（例:「〇〇を使いたい」）の奥に別の目的（例: PDF を編集したい）があり、規則や方針、複数の資料を考え合わせて案内したほうがよい。

    次の JSON だけを出力してください（説明は不要です）:
    {"mode": "direct" または "reasoned", "intent": "質問者が本当に知りたいこと・したいこと（1文）", "queries": ["その目的に合う資料を探す検索語（資料の言語で、最大3つ）"]}
    """
  end

  @doc false
  def parse_plan(text) do
    with [json] <- Regex.run(~r/\{.*\}/su, text),
         {:ok, %{"mode" => "reasoned"} = plan} <- Jason.decode(json) do
      intent = if is_binary(plan["intent"]), do: String.trim(plan["intent"]), else: ""

      queries =
        (plan["queries"] || [])
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.take(@max_queries)

      {:reasoned, intent, queries}
    else
      _ -> :direct
    end
  end

  @doc """
  What a reasoned answer is given: `%{text: the numbered document text, extra: [chunk],
  count: the highest number}`. The excerpts `chunks` keep 1..n; the chunks found by
  `queries` and the rest of the documents (whole, while they fit) follow as n+1…, in each
  document's order. A document too long to give whole is given only the parts found.
  """
  def sources(chunks, queries, setting) do
    n = length(chunks)
    found = chunks ++ search(queries, setting)
    found = Enum.uniq_by(found, & &1.id)
    doc_ids = found |> Enum.map(& &1.document_id) |> Enum.uniq()

    all =
      Repo.all(
        from c in Chunk,
          where: c.document_id in ^doc_ids,
          order_by: [asc: c.document_id, asc: c.position],
          preload: [:document]
      )
      |> Enum.group_by(& &1.document_id)

    found_by_doc = Enum.group_by(found, & &1.document_id)

    {docs, _left} =
      Enum.map_reduce(doc_ids, @total_chars, fn doc_id, left ->
        whole = Map.get(all, doc_id, [])
        size = Enum.sum_by(whole, &String.length(&1.content || ""))

        if whole != [] and size <= @doc_chars and size <= left,
          do: {whole, left - size},
          else: {Enum.sort_by(found_by_doc[doc_id], & &1.position), left}
      end)

    numbers = chunks |> Enum.with_index(1) |> Map.new(fn {c, i} -> {c.id, i} end)

    {numbered, {_numbers, extra}} =
      Enum.map_reduce(docs, {numbers, []}, fn doc_chunks, acc ->
        Enum.map_reduce(doc_chunks, acc, fn chunk, {numbers, extra} ->
          case Map.fetch(numbers, chunk.id) do
            {:ok, k} ->
              {{k, chunk}, {numbers, extra}}

            :error ->
              k = n + length(extra) + 1
              {{k, chunk}, {Map.put(numbers, chunk.id, k), extra ++ [chunk]}}
          end
        end)
      end)

    text =
      Enum.map_join(numbered, "\n\n", fn doc_chunks ->
        [{_, first} | _] = doc_chunks

        "■ #{name(first)}\n" <>
          Enum.map_join(doc_chunks, "\n", fn {k, chunk} ->
            page = if chunk.page, do: " p.#{chunk.page}", else: ""
            "[#{k}]#{page} " <> Snippet.display_text(chunk.content || "")
          end)
      end)

    %{text: text, extra: extra, count: n + length(extra)}
  end

  # the chunks the plan's search words find, each with its own embedding (keyword search
  # alone if that fails)
  defp search([], _setting), do: []

  defp search(queries, setting) do
    embeddings =
      case LLM.embed(setting.embed_model, queries,
             setting: setting,
             purpose: "query_embedding",
             timeout: @embed_timeout,
             retry: false
           ) do
        {:ok, vectors} when length(vectors) == length(queries) -> vectors
        _ -> List.duplicate(nil, length(queries))
      end

    queries
    |> Enum.zip(embeddings)
    |> Enum.flat_map(fn {query, embedding} ->
      query |> Retrieval.excerpts(embedding, @per_query) |> Enum.map(&elem(&1, 0))
    end)
  rescue
    e ->
      Logger.warning("ChatSummary: the plan's search failed: #{Exception.message(e)}")
      []
  end

  @doc "The system instruction for a reasoned answer."
  def system do
    """
    あなたは社内の規則・方針に詳しい問い合わせ窓口のアシスタントです。
    与えられた資料だけを根拠に、質問者の意図を汲み、規則や方針をその目的に照らして考えてから答えます。
    資料に書かれていない事実は付け加えません。
    """
  end

  @doc "The prompt for a reasoned answer, in the question's language."
  def prompt(question, intent, sources, ja?, context_text) do
    intent_line =
      cond do
        intent == "" -> ""
        ja? -> "質問者が本当にしたいこと（見立て）: #{intent}\n"
        true -> "What the person is likely after: #{intent}\n"
      end

    if ja? do
      """
      #{context_text}質問: #{question}
      #{intent_line}
      資料:
      #{sources.text}

      指示:
      - 必ず日本語で答えてください。
      - 質問者が本当に知りたいこと・したいことを考えてから答えてください。
      - 資料の規則・方針は、その目的や背景（なぜその決まりがあるのか）まで読み取り、質問の名前・事例・やりたいことに当てはめて検討してください。
      - 規則や方針に沿っているかを尋ねる質問には、最初に結論（沿っている／沿っていない／資料からは判断できない）を示し、関係する規則ごとに、当てはめた結果とその理由（規則の目的に照らして）を箇条書きで示してください。沿っていない場合は、沿うように直した例を示してください。
      - 何かをしたい・使いたいという質問には、社内の手続き（承認・依頼先など）を示したうえで、質問者の目的に合う別の方法（許可されているアプリなど）が資料にあれば、それも案内してください。
      - 資料に書かれていない事実は加えないでください。考えるのは、資料の規則・方針を当てはめることに限ります。
      - 根拠にした資料の番号を、該当する文の末尾に [1] のように付けてください。
      - 900字以内で答えてください。前置きや質問の言い直しは不要です。
      - 資料に関係する記述が無く答えられない場合だけ、「資料からは確認できませんでした。」とだけ答えてください。
      """
    else
      """
      #{context_text}Question: #{question}
      #{intent_line}
      Documents:
      #{sources.text}

      Instructions:
      - Answer in the same language as the question.
      - Think about what the person really wants to know or do before answering.
      - Read the rules and policies in the documents together with their purpose (why they exist), and apply them to the names, cases or plans in the question.
      - If asked whether something follows the rules, start with the conclusion (follows / does not follow / can't tell from the documents), then for each relevant rule, how it applies and why, in the light of its purpose, as bullets. If it doesn't follow them, show a version that does.
      - If the person wants to do or use something, give the procedure (approvals, whom to ask), then any other way in the documents that serves their aim (an allowed app, for example).
      - Add no facts the documents don't give; the reasoning is only applying their rules and policies.
      - Cite the document parts you rely on at the end of the sentence, like [1].
      - Keep it under 500 words, without preamble.
      - Only if nothing in the documents bears on the question, reply only: "The documents don't cover this."
      """
    end
  end

  @doc """
  The answer with the citations of `extra` (numbered after the `n` excerpts shown) numbered
  n+1… in the order they are first cited, and those chunks: `{text, cited}`. Citations of
  parts not cited are dropped from the text by `ChatSummary.tidy/2` beforehand.
  """
  def renumber(text, n, extra) do
    cited =
      Regex.scan(~r/\[(\d+(?:\s*,\s*\d+)*)\]/u, text, capture: :all_but_first)
      |> Enum.flat_map(fn [numbers] -> numbers(numbers) end)
      |> Enum.filter(&(&1 > n and &1 <= n + length(extra)))
      |> Enum.uniq()

    mapping = cited |> Enum.with_index(n + 1) |> Map.new()

    text =
      Regex.replace(~r/\[(\d+(?:\s*,\s*\d+)*)\]/u, text, fn _whole, numbers ->
        "[" <> (numbers |> numbers() |> Enum.map_join(", ", &Map.get(mapping, &1, &1))) <> "]"
      end)

    {text, Enum.map(cited, &Enum.at(extra, &1 - n - 1))}
  end

  defp numbers(text),
    do: text |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))

  defp name(%Chunk{document: %{name: name}}) when is_binary(name), do: name
  defp name(_), do: "ドキュメント"
end
