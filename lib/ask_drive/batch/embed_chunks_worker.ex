defmodule AskDrive.Batch.EmbedChunksWorker do
  @moduledoc """
  Oban worker for extracting text, chunking, and embedding document vectors into SQLite and `sqlite-vec`.
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 3

  import Ecto.Query, warn: false
  require Logger

  alias AskDrive.{Documents, Freshness, Repo, Settings, Vector}
  alias AskDrive.Batch.ItemLog
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.Ingest.{Chunker, Extractor}
  alias AskDrive.LLM
  alias AskDrive.LLM.Semaphore

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => document_id} = args}) do
    doc = Documents.get_document!(document_id)
    started = System.monotonic_time(:millisecond)

    result =
      try do
        index_document(doc)
      rescue
        e ->
          Logger.error(
            "EmbedChunksWorker: crashed on #{doc.name}: #{Exception.format(:error, e, __STACKTRACE__)}"
          )

          Documents.mark_failed(doc, Exception.message(e))
          {:error, {:exception, Exception.message(e)}}
      end

    log_outcome(args["batch_run_id"], doc, result, System.monotonic_time(:millisecond) - started)
    result
  end

  defp log_outcome(run_id, doc, result, duration_ms) do
    {status, chunks, message} =
      case result do
        {:ok, {:indexed, %{total: n, new: new, reused: reused, removed: removed}}} ->
          {"indexed", n,
           "新規 #{new} / 再利用 #{reused} / 削除 #{removed} チャンク" <>
             if(reused > 0, do: "（変更のないチャンクは埋め込み・QA を再利用）", else: "")}

        {:ok, :unchanged} ->
          {"unchanged", nil, "本文に変更がないため、分割・埋め込みを省略しました"}

        {:ok, :empty_content} ->
          {"empty", 0, "本文が空でした（抽出できるテキストがありません）"}

        {:ok, :skipped} ->
          {"skipped", nil, Documents.get_document!(doc.id).error}

        {:error, {:embedding, reason}} ->
          {"failed", nil, "埋め込みに失敗: " <> ItemLog.describe_reason(reason)}

        {:error, {:exception, msg}} ->
          {"failed", nil, "処理中に例外: " <> msg}

        {:error, reason} ->
          {"failed", nil, "本文の取得・抽出に失敗: " <> ItemLog.describe_reason(reason)}
      end

    Logger.info(
      "EmbedChunksWorker: #{status} #{doc.name} (#{doc.mime_type}, #{duration_ms}ms" <>
        if(chunks, do: ", #{chunks} chunks", else: "") <>
        if(message, do: ") — #{message}", else: ")")
    )

    ItemLog.record(run_id, %{
      phase: "embed_chunks",
      document_id: doc.id,
      drive_file_id: doc.drive_file_id,
      name: doc.path || doc.name,
      mime_type: doc.mime_type,
      status: status,
      chunks: chunks,
      message: message,
      duration_ms: duration_ms
    })
  end

  defp index_document(doc) do
    setting = Settings.get_setting!()

    Logger.info("EmbedChunksWorker: Processing document #{doc.name} (id: #{doc.id})...")

    case Extractor.extract_from_drive(doc) do
      {:skipped, reason} ->
        Logger.info("EmbedChunksWorker: Skipped #{doc.name}: #{reason}")
        Documents.mark_skipped(doc, reason)
        {:ok, :skipped}

      {:error, reason} ->
        Logger.error("EmbedChunksWorker: Extraction failed for #{doc.name}: #{inspect(reason)}")
        Documents.mark_failed(doc, inspect(reason))
        {:error, reason}

      {:ok, %{text: text, content_hash: hash}} ->
        index_text(doc, text, hash, setting)
    end
  end

  @doc """
  Indexes extracted text, skipping everything when it is identical to what is indexed.

  Sync has already put the document back to "pending" by the time we get here, so the old
  `status == "indexed"` condition never held and identical text was always re-chunked and
  re-embedded (spec F-335). What matters is the same text with chunks present.
  """
  def index_text(%Document{} = doc, text, hash, setting) do
    if doc.content_hash == hash and has_chunks?(doc) do
      Documents.mark_indexed(doc, hash)
      {:ok, :unchanged}
    else
      process_chunks_and_embed(doc, text, hash, setting)
    end
  end

  defp has_chunks?(doc), do: Repo.exists?(from c in Chunk, where: c.document_id == ^doc.id)

  @doc """
  Chunks `text` and brings the document's chunks up to date incrementally (spec F-336):
  a new chunk whose `content_hash` matches an existing chunk of this document reuses that
  row — its embedding and its generated QA stay as they are — so only genuinely new chunks
  are embedded, and only QA of chunks that disappeared goes stale. Editing one paragraph of
  a long manual no longer re-embeds and re-generates the whole manual.
  """
  def process_chunks_and_embed(%Document{} = doc, text, hash, setting) do
    chunks_data = Chunker.chunk(text, doc_name: doc.name)
    existing = Repo.all(from c in Chunk, where: c.document_id == ^doc.id, order_by: c.position)
    {plan, removed} = plan_chunks(chunks_data, existing)

    new_texts = for {:new, data} <- plan, do: data.content

    case embed_in_batches(new_texts, setting) do
      {:ok, embeddings} ->
        {:ok, stats} = save_chunks_transaction(doc, plan, removed, embeddings, hash)

        if chunks_data == [],
          do: {:ok, :empty_content},
          else: {:ok, {:indexed, stats}}

      {:error, reason} ->
        Logger.error("EmbedChunksWorker: Embedding failed for #{doc.name}: #{inspect(reason)}")
        Documents.mark_failed(doc, "Embedding failed: #{inspect(reason)}")
        {:error, {:embedding, reason}}
    end
  end

  # Pairs each new chunk with an unused existing chunk of the same content_hash
  # ({:reuse, chunk, data}) or marks it {:new, data}; existing chunks left over are removed.
  defp plan_chunks(chunks_data, existing) do
    pool = Enum.group_by(existing, & &1.content_hash)

    {plan, pool} =
      Enum.map_reduce(chunks_data, pool, fn data, pool ->
        case Map.get(pool, data.content_hash, []) do
          [chunk | rest] -> {{:reuse, chunk, data}, Map.put(pool, data.content_hash, rest)}
          [] -> {{:new, data}, pool}
        end
      end)

    {plan, pool |> Map.values() |> List.flatten()}
  end

  # One request per whole document timed out on long PDFs: a 186-chunk manual took 29s
  # against the provider's 30s embed timeout. Fixed-size batches keep every request well
  # inside it no matter how long the document is, and each batch takes the semaphore on its
  # own so a long document doesn't starve chat queries needing a query embedding.
  @embed_batch_size 32

  defp embed_in_batches([], _setting), do: {:ok, []}

  defp embed_in_batches(texts, setting) do
    texts
    |> Enum.chunk_every(@embed_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case Semaphore.run(fn -> LLM.embed(setting.embed_model, batch, setting: setting) end) do
        {:ok, vectors} -> {:cont, {:ok, [vectors | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, batches} -> {:ok, batches |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  defp save_chunks_transaction(doc, plan, removed, embeddings, hash) do
    Repo.transaction(fn ->
      changed? = removed != [] or Enum.any?(plan, &match?({:new, _}, &1))

      # 1. Chunks that no longer exist: their QA / extractions go stale (and leave the answer
      #    cache), then the rows and their vectors go. Reused chunks keep their QA.
      Enum.each(removed, fn chunk ->
        Freshness.invalidate_chunk(chunk)
        Repo.query!("DELETE FROM vec_chunks WHERE chunk_id = ?", [chunk.id])
        Repo.delete!(chunk)
      end)

      # 2. Document-level artifacts (summaries) describe the whole text: stale on any change.
      if changed?, do: Freshness.invalidate_document_level(doc)

      # 3. Reused chunks: only position/heading/page can differ.
      # 4. New chunks: insert with their fresh embeddings, in plan order.
      {_rest, counts} =
        Enum.reduce(plan, {embeddings, %{new: 0, reused: 0}}, fn
          {:reuse, chunk, data}, {embs, counts} ->
            if chunk.position != data.position or chunk.heading != data.heading or
                 chunk.page != data[:page] do
              chunk
              |> Chunk.changeset(%{
                position: data.position,
                heading: data.heading,
                page: data[:page]
              })
              |> Repo.update!()
            end

            {embs, %{counts | reused: counts.reused + 1}}

          {:new, data}, {[emb | embs], counts} ->
            {:ok, new_chunk} =
              %Chunk{}
              |> Chunk.changeset(
                data
                |> Map.put(:document_id, doc.id)
                |> Map.put(:embedding, Vector.encode(emb))
              )
              |> Repo.insert()

            Repo.query!(
              "INSERT INTO vec_chunks(chunk_id, embedding) VALUES (?, ?)",
              [new_chunk.id, Vector.to_json(emb)]
            )

            {embs, %{counts | new: counts.new + 1}}
        end)

      {:ok, _} = Documents.mark_indexed(doc, hash)

      counts
      |> Map.put(:removed, length(removed))
      |> Map.put(:total, length(plan))
    end)
  end
end
