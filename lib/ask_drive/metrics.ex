defmodule AskDrive.Metrics do
  @moduledoc """
  Context for logging and analyzing LLM and API usage metrics (tokens, payload size, latency, errors)
  without logging confidential user prompts or search terms (spec 14.5, N-606).
  """
  use Gettext, backend: AskDriveWeb.Gettext
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

    rate_limit_errors =
      Repo.one(
        from l in base_query,
          where:
            l.status == "error" and
              (like(l.error_message, "%429%") or like(l.error_message, "%rate_limited%")),
          select: count(l.id)
      ) || 0

    %{
      days: days,
      total_requests: total_requests,
      error_requests: error_requests,
      rate_limit_errors: rate_limit_errors,
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
  Determines the format of a document from its name and mime_type, as a language-neutral key.
  """
  def format_key(doc) do
    name = (doc.name || "") |> String.downcase()
    mime = (doc.mime_type || "") |> String.downcase()

    cond do
      String.ends_with?(name, ".md") or String.ends_with?(name, ".markdown") ->
        :markdown

      String.ends_with?(name, ".txt") or mime == "text/plain" ->
        :plain_text

      String.ends_with?(name, ".csv") or String.ends_with?(name, ".tsv") or
          mime in ["text/csv", "text/tab-separated-values"] ->
        :csv

      String.contains?(mime, "google-apps.document") or String.ends_with?(name, ".docx") or
          String.ends_with?(name, ".doc") ->
        :docs

      String.contains?(mime, "google-apps.spreadsheet") or String.ends_with?(name, ".xlsx") or
          String.ends_with?(name, ".xls") ->
        :sheets

      String.contains?(mime, "google-apps.presentation") or String.ends_with?(name, ".pptx") or
          String.ends_with?(name, ".ppt") ->
        :slides

      String.ends_with?(name, ".pdf") or mime == "application/pdf" ->
        :pdf

      String.ends_with?(name, ".png") or String.ends_with?(name, ".jpg") or
        String.ends_with?(name, ".jpeg") or String.starts_with?(mime, "image/") ->
        :image

      true ->
        :other
    end
  end

  @doc """
  Determines human-friendly format category from document name and mime_type, in the current
  locale. Every label starts with the format name the admin screen keys its colours on
  ("Markdown", "Plain", "CSV", "Docs", "Sheets", "PDF").
  """
  def format_category(doc), do: format_label(format_key(doc))

  defp format_label(:markdown), do: gettext("Markdown (structured text)")
  defp format_label(:plain_text), do: gettext("Plain Text (plain)")
  defp format_label(:csv), do: gettext("CSV / TSV (tabular)")
  defp format_label(:docs), do: gettext("Docs / Word (document)")
  defp format_label(:sheets), do: gettext("Sheets / Excel (spreadsheet)")
  defp format_label(:slides), do: gettext("Slides / PowerPoint (slides)")
  defp format_label(:pdf), do: gettext("PDF document")
  defp format_label(:image), do: gettext("Image / OCR target")
  defp format_label(:other), do: gettext("Other")

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

    format = format_key(doc)
    category = format_label(format)

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

    # pages: as recorded when indexed, else the last page a chunk starts on (F-1410)
    pages =
      doc.page_count ||
        chunks |> Enum.map(& &1.page) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

    chars_per_page = if pages && pages > 0, do: Float.round(total_chars / pages, 1)

    {score_level, score_rating, advice} =
      evaluate_efficiency(format, tokens_per_kb, chunks_count, %{
        pages: pages,
        chars_per_page: chars_per_page,
        textless_pages: doc.textless_pages,
        total_chars: total_chars,
        refers_to_images?: refers_to_images?(chunks)
      })

    %{
      document: doc,
      category: category,
      raw_size_bytes: raw_size_bytes,
      total_tokens: total_tokens,
      total_chars: total_chars,
      chunks_count: chunks_count,
      tokens_per_kb: tokens_per_kb,
      effective_text_ratio: effective_text_ratio,
      pages: pages,
      chars_per_page: chars_per_page,
      score_level: score_level,
      score_rating: score_rating,
      advice: advice
    }
  end

  # {score_level, score_rating, advice}: score_level is the language-neutral grade the admin
  # screen picks the badge colour from; score_rating and advice are display text.
  #
  # PDFs are judged by their text per page, not by text against file size (F-1410): the
  # screenshots that make a manual easy to follow make the file large without adding text,
  # so a well-written manual with many of them used to be rated "Needs improvement".
  # Only a PDF with (almost) no text on its pages — a scan, images only — is.
  defp evaluate_efficiency(format, tokens_per_kb, chunks_count, text) do
    cond do
      chunks_count == 0 ->
        {:none, "—", gettext("No indexed chunks")}

      format in [:markdown, :plain_text] ->
        {:excellent, gettext("Excellent (S)"),
         gettext(
           "Structured text: ideal data with the highest tokenisation and search efficiency."
         )}

      format in [:csv, :sheets] ->
        if tokens_per_kb > 50.0 do
          {:good, gettext("Good (A)"), gettext("Indexed efficiently as tabular data.")}
        else
          {:fair, gettext("Fair (B)"),
           gettext(
             "Removing unneeded blank cells and oversized header rows improves token efficiency."
           )}
        end

      format == :docs ->
        {:good, gettext("Good (A)"),
         with_image_note(
           gettext("Well-structured document with stable token efficiency."),
           text
         )}

      format == :pdf and scanned?(text) ->
        {:poor, gettext("Needs improvement (C)"),
         gettext(
           "Almost no text on its pages: it looks like scanned pages or images only. Their content can't be searched; converting it to the original text or Markdown is recommended."
         )}

      format == :pdf ->
        {:fair, gettext("Fair (B)"), pdf_advice(text)}

      format == :image ->
        {:warning, gettext("Caution (D)"),
         gettext(
           "Mostly image data. Transcribing it to text (Markdown) can greatly improve search accuracy and save tokens."
         )}

      format == :slides ->
        {:fair, gettext("Fair (B)"), with_image_note(gettext("Standard file format."), text)}

      true ->
        {:fair, gettext("Fair (B)"), gettext("Standard file format.")}
    end
  end

  # fewer characters per page than a short caption: nothing but images
  @scanned_chars_per_page 50

  defp scanned?(%{chars_per_page: nil, total_chars: chars}), do: chars < @scanned_chars_per_page
  defp scanned?(%{chars_per_page: per_page}), do: per_page < @scanned_chars_per_page

  defp pdf_advice(text) do
    base =
      if text.refers_to_images?,
        do:
          gettext(
            "Explained with screenshots or figures: the text is indexed correctly, and the images are where they belong."
          ),
        else:
          gettext(
            "Text is extracted from the PDF. Converting it to Markdown or Docs with clear headings improves accuracy further."
          )

    textless =
      if (text.textless_pages || 0) > 0 and text.pages,
        do:
          gettext(
            "%{count} of %{pages} pages have no text (images only); if what they show matters, write it in the text too.",
            count: text.textless_pages,
            pages: text.pages
          )

    image_note = if text.refers_to_images?, do: images_not_searchable()

    [base, textless, image_note] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp with_image_note(advice, %{refers_to_images?: true}),
    do: advice <> " " <> images_not_searchable()

  defp with_image_note(advice, _text), do: advice

  defp images_not_searchable,
    do:
      gettext(
        "Text inside the images (button names, values) isn't searched: writing the important ones in the text as well makes them findable."
      )

  # "click the button in the red frame of the image below": the images are part of the
  # explanation, not a sign of a poorly converted file
  @image_reference ~r/(以下|下記|次|上記|下|上)の(画像|図|スクリーンショット|画面|キャプチャ)|赤枠|赤い枠|赤線|スクリーンショット|スクショ|キャプチャ画像|下図|上図|図\s*[0-9０-９]|画像のよう|screenshot|(image|figure|picture) (below|above)|red (box|frame|rectangle)|\bfig(ure)?\.?\s*\d/iu

  @doc false
  def refers_to_images?(chunks),
    do: Enum.any?(chunks, &Regex.match?(@image_reference, &1.content || ""))

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
