defmodule AskDrive.Metrics do
  @moduledoc """
  Context for logging and analyzing LLM and API usage metrics (tokens, payload size, latency, errors)
  without logging confidential user prompts or search terms (spec 14.5, N-606).
  """
  import Ecto.Query, warn: false
  require Logger

  alias AskDrive.Metrics.ApiUsageLog
  alias AskDrive.Repo

  @doc """
  Records an API usage log entry safely. Does not raise or fail callers if logging encounters an issue.
  """
  def record(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    # Calculate total_tokens if not provided
    prompt_tokens = Map.get(attrs, :prompt_tokens) || Map.get(attrs, "prompt_tokens") || 0

    completion_tokens =
      Map.get(attrs, :completion_tokens) || Map.get(attrs, "completion_tokens") || 0

    total_tokens =
      Map.get(attrs, :total_tokens) || Map.get(attrs, "total_tokens") ||
        prompt_tokens + completion_tokens

    attrs =
      attrs
      |> Map.put(:prompt_tokens, prompt_tokens)
      |> Map.put(:completion_tokens, completion_tokens)
      |> Map.put(:total_tokens, total_tokens)

    try do
      %ApiUsageLog{}
      |> ApiUsageLog.changeset(attrs)
      |> Repo.insert()

      :ok
    rescue
      e ->
        Logger.warning("Metrics.record failed: #{inspect(e)}")
        :ok
    end
  end

  @doc """
  Returns high-level summary statistics of API usage for the current Repo.
  """
  def get_summary(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days * 86400, :second)

    base_query = from l in ApiUsageLog, where: l.inserted_at >= ^since

    total_requests = Repo.aggregate(base_query, :count, :id) || 0

    error_requests =
      Repo.one(from l in base_query, where: l.status == "error", select: count(l.id)) || 0

    totals =
      Repo.one(
        from l in base_query,
          select: %{
            prompt_tokens: coalesce(sum(l.prompt_tokens), 0),
            completion_tokens: coalesce(sum(l.completion_tokens), 0),
            total_tokens: coalesce(sum(l.total_tokens), 0),
            total_bytes: coalesce(sum(l.request_bytes), 0),
            avg_latency: coalesce(avg(l.latency_ms), 0.0)
          }
      ) ||
        %{
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
          total_bytes: 0,
          avg_latency: 0.0
        }

    provider_breakdown =
      Repo.all(
        from l in base_query,
          group_by: [l.provider, l.model],
          select: %{
            provider: l.provider,
            model: l.model,
            requests: count(l.id),
            total_tokens: coalesce(sum(l.total_tokens), 0),
            errors: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status))
          },
          order_by: [desc: count(l.id)]
      )

    purpose_breakdown =
      Repo.all(
        from l in base_query,
          group_by: l.purpose,
          select: %{
            purpose: l.purpose,
            requests: count(l.id),
            total_tokens: coalesce(sum(l.total_tokens), 0)
          },
          order_by: [desc: count(l.id)]
      )

    %{
      days: days,
      total_requests: total_requests,
      error_requests: error_requests,
      success_rate:
        if(total_requests > 0,
          do: Float.round((total_requests - error_requests) / total_requests * 100, 1),
          else: 100.0
        ),
      prompt_tokens: totals.prompt_tokens,
      completion_tokens: totals.completion_tokens,
      total_tokens: totals.total_tokens,
      total_bytes: totals.total_bytes,
      avg_latency_ms: round(totals.avg_latency),
      provider_breakdown: provider_breakdown,
      purpose_breakdown: purpose_breakdown
    }
  end

  @doc """
  Lists recent API error logs (for debugging failures).
  """
  def list_recent_errors(limit \\ 20) do
    Repo.all(
      from l in ApiUsageLog,
        where: l.status == "error",
        order_by: [desc: l.inserted_at],
        limit: ^limit
    )
  end

  @doc """
  Lists recent API usage logs.
  """
  def list_recent_logs(limit \\ 50) do
    Repo.all(
      from l in ApiUsageLog,
        order_by: [desc: l.inserted_at],
        limit: ^limit
    )
  end

  # --- Data & Ingestion Token Efficiency (spec 14.6) -------------------------

  alias AskDrive.Documents.{Chunk, Document}

  @doc """
  Determines human-friendly format category from document name and mime_type.
  """
  def format_category(doc) do
    name = (doc.name || "") |> String.downcase()
    mime = (doc.mime_type || "") |> String.downcase()

    cond do
      String.ends_with?(name, ".md") or String.ends_with?(name, ".markdown") ->
        "Markdown (構造化テキスト)"

      String.ends_with?(name, ".txt") or mime == "text/plain" ->
        "Plain Text (平文)"

      String.ends_with?(name, ".csv") or String.ends_with?(name, ".tsv") or
          mime in ["text/csv", "text/tab-separated-values"] ->
        "CSV / TSV (表形式)"

      String.contains?(mime, "google-apps.document") or String.ends_with?(name, ".docx") or
          String.ends_with?(name, ".doc") ->
        "Docs / Word (文書)"

      String.contains?(mime, "google-apps.spreadsheet") or String.ends_with?(name, ".xlsx") or
          String.ends_with?(name, ".xls") ->
        "Sheets / Excel (表計算)"

      String.contains?(mime, "google-apps.presentation") or String.ends_with?(name, ".pptx") or
          String.ends_with?(name, ".ppt") ->
        "Slides / PowerPoint (スライド)"

      String.ends_with?(name, ".pdf") or mime == "application/pdf" ->
        "PDF 文書"

      String.ends_with?(name, ".png") or String.ends_with?(name, ".jpg") or
        String.ends_with?(name, ".jpeg") or String.starts_with?(mime, "image/") ->
        "画像 / OCR対象"

      true ->
        "その他"
    end
  end

  @doc """
  Calculates token efficiency details for a given document with its preloaded or queried chunks.
  """
  def calculate_doc_efficiency(%Document{} = doc, chunks \\ nil) do
    chunks = chunks || Repo.all(from c in Chunk, where: c.document_id == ^doc.id)
    raw_size_bytes = doc.size_bytes || 0
    total_tokens = Enum.reduce(chunks, 0, fn c, acc -> acc + (c.token_estimate || 0) end)
    total_chars = Enum.reduce(chunks, 0, fn c, acc -> acc + String.length(c.content || "") end)
    extracted_bytes = Enum.reduce(chunks, 0, fn c, acc -> acc + byte_size(c.content || "") end)
    chunks_count = length(chunks)

    category = format_category(doc)

    # Calculate token density (Tokens per 1 KB of source file)
    # Higher is generally cleaner for text; for image/PDF, a huge raw file with tiny tokens yields low density.
    tokens_per_kb =
      if raw_size_bytes > 0 do
        Float.round(total_tokens / (raw_size_bytes / 1024), 1)
      else
        # If size_bytes is 0 (like pure Google Doc export), consider extracted_bytes
        if extracted_bytes > 0,
          do: Float.round(total_tokens / (extracted_bytes / 1024), 1),
          else: 0.0
      end

    # Effective text ratio: extracted text bytes vs raw file size
    effective_text_ratio =
      if raw_size_bytes > 0 do
        min(100.0, Float.round(extracted_bytes / raw_size_bytes * 100, 1))
      else
        100.0
      end

    {score_rating, advice} =
      evaluate_efficiency(category, tokens_per_kb, effective_text_ratio, chunks_count)

    %{
      document: doc,
      category: category,
      raw_size_bytes: raw_size_bytes,
      total_tokens: total_tokens,
      total_chars: total_chars,
      chunks_count: chunks_count,
      tokens_per_kb: tokens_per_kb,
      effective_text_ratio: effective_text_ratio,
      score_rating: score_rating,
      advice: advice
    }
  end

  defp evaluate_efficiency(category, tokens_per_kb, effective_text_ratio, chunks_count) do
    cond do
      chunks_count == 0 ->
        {"—", "インデックス化されたチャンクがありません"}

      String.starts_with?(category, "Markdown") or String.starts_with?(category, "Plain Text") ->
        {"優良 (S)", "構造化されたテキスト形式で、トークン化および検索効率が最も高い理想的なデータです。"}

      String.starts_with?(category, "CSV") or String.starts_with?(category, "Sheets") ->
        if tokens_per_kb > 50.0 do
          {"良好 (A)", "表形式データとして効率よくインデックス化されています。"}
        else
          {"普通 (B)", "不要な空欄や巨大なヘッダー行を整理するとトークン効率が向上します。"}
        end

      String.starts_with?(category, "Docs") ->
        {"良好 (A)", "文書構造が整っており、安定したトークン効率です。"}

      String.starts_with?(category, "PDF") ->
        if effective_text_ratio < 10.0 and tokens_per_kb < 10.0 do
          {"要改善 (C)", "ファイルサイズに対して抽出文字数が少なめです。スキャン画像が多い場合はテキスト原本やMarkdownへの変換を推奨します。"}
        else
          {"普通 (B)", "PDFからテキスト抽出されています。見出し構成が明確なMarkdownやDocsにするとさらに精度が上がります。"}
        end

      String.starts_with?(category, "画像") ->
        {"注意 (D)", "画像主体のデータです。テキスト書き起こし（Markdown化）を行うことで大幅な検索精度向上とトークン節約が期待できます。"}

      true ->
        {"普通 (B)", "標準的なファイル形式です。"}
    end
  end

  @doc """
  Aggregates data token efficiency metrics across all indexed documents.
  """
  def get_data_efficiency_summary do
    docs =
      Repo.all(from d in Document, where: d.status == "indexed", order_by: [desc: d.updated_at])

    chunks = Repo.all(from c in Chunk, select: {c.document_id, c.token_estimate, c.content})

    chunks_by_doc =
      Enum.group_by(chunks, fn {doc_id, _tok, _cnt} -> doc_id end, fn {_id, tok, cnt} ->
        %Chunk{token_estimate: tok, content: cnt}
      end)

    doc_stats =
      Enum.map(docs, fn doc ->
        doc_chunks = Map.get(chunks_by_doc, doc.id, [])
        calculate_doc_efficiency(doc, doc_chunks)
      end)

    total_indexed_docs = length(doc_stats)
    total_tokens = Enum.reduce(doc_stats, 0, fn d, acc -> acc + d.total_tokens end)
    total_raw_bytes = Enum.reduce(doc_stats, 0, fn d, acc -> acc + d.raw_size_bytes end)

    avg_tokens_per_kb =
      if total_raw_bytes > 0 do
        Float.round(total_tokens / (total_raw_bytes / 1024), 1)
      else
        0.0
      end

    format_breakdown =
      doc_stats
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {category, items} ->
        cat_docs = length(items)
        cat_tokens = Enum.reduce(items, 0, fn i, acc -> acc + i.total_tokens end)
        cat_bytes = Enum.reduce(items, 0, fn i, acc -> acc + i.raw_size_bytes end)

        avg_density =
          if cat_bytes > 0, do: Float.round(cat_tokens / (cat_bytes / 1024), 1), else: 0.0

        avg_ratio =
          if cat_docs > 0,
            do: Float.round(Enum.sum(Enum.map(items, & &1.effective_text_ratio)) / cat_docs, 1),
            else: 0.0

        %{
          category: category,
          docs_count: cat_docs,
          total_tokens: cat_tokens,
          total_bytes: cat_bytes,
          avg_density: avg_density,
          avg_ratio: avg_ratio
        }
      end)
      |> Enum.sort_by(& &1.docs_count, :desc)

    %{
      total_indexed_docs: total_indexed_docs,
      total_tokens: total_tokens,
      total_raw_bytes: total_raw_bytes,
      avg_tokens_per_kb: avg_tokens_per_kb,
      format_breakdown: format_breakdown,
      doc_stats: doc_stats
    }
  end
end
