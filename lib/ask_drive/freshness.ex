defmodule AskDrive.Freshness do
  @moduledoc """
  Handles freshness tracking, stale invalidation, and cache eviction across documents, chunks, QAs, and caches.

  Dependency chain:
  Document updated / Content hash changed
    └→ Document chunks replaced
         └→ QA pairs referencing old chunk hash / document marked `stale`
              └→ Answer cache entries for stale QA pairs deleted immediately
         └→ Doc summaries referencing document marked `stale`
         └→ Extractions referencing document/chunks marked `stale`
  """
  require Logger
  import Ecto.Query, warn: false

  alias AskDrive.Documents.{Chunk, DocSummary, Document, Extraction}
  alias AskDrive.QA.{AnswerCache, QAPair}
  alias AskDrive.Repo

  @doc """
  Invalidates all generated artifacts (QAs, summaries, extractions) belonging to a modified document.
  Also purges all answer_cache entries pointing to invalidated QAs.
  """
  def invalidate_document(%Document{} = doc) do
    Repo.transaction(fn ->
      # 1. Find all active QAs for this document
      qa_ids =
        Repo.all(
          from q in QAPair,
            where: q.document_id == ^doc.id and q.status == "active",
            select: q.id
        )

      # 2. Delete all answer_cache entries pointing to these QAs (F-503, 10-7)
      if qa_ids != [] do
        Repo.delete_all(from c in AnswerCache, where: c.qa_pair_id in ^qa_ids)
      end

      # 3. Mark QA pairs as stale
      {stale_qas_count, _} =
        Repo.update_all(
          from(q in QAPair, where: q.document_id == ^doc.id and q.status == "active"),
          set: [status: "stale"]
        )

      # 4. Mark doc summaries as stale
      {stale_summaries_count, _} =
        Repo.update_all(
          from(s in DocSummary, where: s.document_id == ^doc.id and s.status == "active"),
          set: [status: "stale"]
        )

      # 5. Mark extractions as stale
      {stale_extractions_count, _} =
        Repo.update_all(
          from(e in Extraction, where: e.document_id == ^doc.id and e.status == "active"),
          set: [status: "stale"]
        )

      Logger.info(
        "Freshness: Invalidated document #{doc.name} (id: #{doc.id}) -> #{stale_qas_count} QAs, #{stale_summaries_count} summaries, #{stale_extractions_count} extractions marked stale."
      )

      %{
        qas: stale_qas_count,
        summaries: stale_summaries_count,
        extractions: stale_extractions_count
      }
    end)
  end

  @doc """
  Invalidates generated artifacts for a specific chunk when its content hash changed.
  """
  def invalidate_chunk(%Chunk{} = chunk) do
    Repo.transaction(fn ->
      # 1. Find QAs belonging to this chunk that have mismatched hash or are active
      qa_ids =
        Repo.all(
          from q in QAPair,
            where: q.chunk_id == ^chunk.id and q.status == "active",
            select: q.id
        )

      if qa_ids != [] do
        # Evict cache
        Repo.delete_all(from c in AnswerCache, where: c.qa_pair_id in ^qa_ids)
      end

      {stale_qas, _} =
        Repo.update_all(
          from(q in QAPair, where: q.chunk_id == ^chunk.id and q.status == "active"),
          set: [status: "stale"]
        )

      {stale_extractions, _} =
        Repo.update_all(
          from(e in Extraction, where: e.chunk_id == ^chunk.id and e.status == "active"),
          set: [status: "stale"]
        )

      %{qas: stale_qas, extractions: stale_extractions}
    end)
  end

  @doc """
  Completely deletes a document and all related chunks, QAs, vector indices, summaries, extractions, and caches (F-506).
  """
  def delete_document_completely(%Document{} = doc) do
    Repo.transaction(fn ->
      # 1. Collect QA IDs
      qa_ids =
        Repo.all(
          from q in QAPair,
            where: q.document_id == ^doc.id,
            select: q.id
        )

      # 2. Collect Chunk IDs
      chunk_ids =
        Repo.all(
          from c in Chunk,
            where: c.document_id == ^doc.id,
            select: c.id
        )

      # 3. Clean virtual vector tables
      Enum.each(qa_ids, fn id ->
        Repo.query("DELETE FROM vec_qa_pairs WHERE qa_pair_id = ?", [id])
      end)

      Enum.each(chunk_ids, fn id ->
        # chunks_fts follows chunks through triggers (migration SyncChunksFts)
        Repo.query("DELETE FROM vec_chunks WHERE chunk_id = ?", [id])
      end)

      # 4. Delete document record (Ecto cascade deletes chunks, qas, answer_cache, summaries, extractions)
      Repo.delete(doc)
    end)
  end
end
