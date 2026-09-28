defmodule AskDrive.Batch.EmbedChunksWorker do
  @moduledoc """
  Oban worker for extracting text, chunking, and embedding document vectors into SQLite and `sqlite-vec`.
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 3

  import Ecto.Query, warn: false
  require Logger

  alias AskDrive.{Documents, Repo, Settings, Vector}
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
        {:ok, {:indexed, n}} ->
          {"indexed", n, nil}

        {:ok, :unchanged} ->
          {"unchanged", nil, "内容に変更がないため再取り込みを省略しました"}

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
        if doc.content_hash == hash and doc.status == "indexed" do
          Logger.info("EmbedChunksWorker: Document #{doc.name} content unchanged. Skipping.")
          {:ok, :unchanged}
        else
          process_chunks_and_embed(doc, text, hash, setting)
        end
    end
  end

  def process_chunks_and_embed(%Document{} = doc, text, hash, setting) do
    chunks_data = Chunker.chunk(text, doc_name: doc.name)

    if Enum.empty?(chunks_data) do
      Documents.mark_indexed(doc, hash)
      {:ok, :empty_content}
    else
      chunk_texts = Enum.map(chunks_data, & &1.content)

      # Concurrency-controlled embedding via Ollama
      embed_result =
        Semaphore.run(fn ->
          LLM.embed(setting.embed_model, chunk_texts, setting: setting)
        end)

      case embed_result do
        {:ok, embeddings} ->
          {:ok, :ok} = save_chunks_transaction(doc, chunks_data, embeddings, hash)
          {:ok, {:indexed, length(chunks_data)}}

        {:error, reason} ->
          Logger.error("EmbedChunksWorker: Embedding failed for #{doc.name}: #{inspect(reason)}")
          Documents.mark_failed(doc, "Embedding failed: #{inspect(reason)}")
          {:error, {:embedding, reason}}
      end
    end
  end

  defp save_chunks_transaction(doc, chunks_data, embeddings, hash) do
    Repo.transaction(fn ->
      # Invalidate previous QAs, summaries, extractions and answer_cache entries
      AskDrive.Freshness.invalidate_document(doc)

      # 1. Remove old chunks and old vec_chunks entries
      old_chunk_ids =
        Repo.all(from c in Chunk, where: c.document_id == ^doc.id, select: c.id)

      Enum.each(old_chunk_ids, fn cid ->
        Repo.query!("DELETE FROM vec_chunks WHERE chunk_id = ?", [cid])
      end)

      Repo.delete_all(from c in Chunk, where: c.document_id == ^doc.id)

      # 2. Insert new chunks and vec_chunks
      Enum.zip(chunks_data, embeddings)
      |> Enum.each(fn {c_data, emb_floats} ->
        blob = Vector.encode(emb_floats)
        json_vec = Vector.to_json(emb_floats)

        {:ok, new_chunk} =
          %Chunk{}
          |> Chunk.changeset(
            c_data
            |> Map.put(:document_id, doc.id)
            |> Map.put(:embedding, blob)
          )
          |> Repo.insert()

        Repo.query!(
          "INSERT INTO vec_chunks(chunk_id, embedding) VALUES (?, ?)",
          [new_chunk.id, json_vec]
        )
      end)

      # 3. Mark document indexed
      {:ok, _} = Documents.mark_indexed(doc, hash)
      :ok
    end)
  end
end
