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
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.Ingest.{Chunker, Extractor}
  alias AskDrive.LLM.{Ollama, Semaphore}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => document_id}}) do
    doc = Documents.get_document!(document_id)
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
          Ollama.embed(setting.embed_model, chunk_texts)
        end)

      case embed_result do
        {:ok, embeddings} ->
          save_chunks_transaction(doc, chunks_data, embeddings, hash)

        {:error, reason} ->
          Logger.error("EmbedChunksWorker: Embedding failed for #{doc.name}: #{inspect(reason)}")
          Documents.mark_failed(doc, "Embedding failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp save_chunks_transaction(doc, chunks_data, embeddings, hash) do
    Repo.transaction(fn ->
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
