defmodule AskDrive.Retrieval do
  @moduledoc """
  Hybrid retrieval engine combining sqlite-vec vector search with SQLite FTS5 (trigram) full-text search,
  merged using Reciprocal Rank Fusion (RRF).
  """
  import Ecto.Query, warn: false
  alias AskDrive.Repo
  alias AskDrive.Documents.Chunk
  alias AskDrive.Vector

  @rrf_k 60
  @max_chunks_per_doc 3

  @doc """
  Performs vector similarity search against `vec_chunks`.
  Returns `[{chunk_id, distance}]`.
  """
  def vector_search(query_embedding, limit \\ 20) when is_list(query_embedding) do
    json_vec = Vector.to_json(query_embedding)

    sql = """
    SELECT chunk_id, distance
    FROM vec_chunks
    WHERE embedding MATCH ? AND k = ?
    ORDER BY distance ASC
    """

    case Repo.query(sql, [json_vec, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [chunk_id, dist] -> {chunk_id, dist} end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Performs keyword/full-text search against `chunks_fts` (trigram tokenizer).
  Falls back to LIKE search for very short queries (1-2 chars) or if FTS returns no results.
  Returns `[{chunk_id, rank}]`.
  """
  def keyword_search(query_text, limit \\ 20) when is_binary(query_text) do
    trimmed = String.trim(query_text)

    if String.length(trimmed) <= 2 do
      like_search(trimmed, limit)
    else
      # Escape FTS special chars
      clean_query = String.replace(trimmed, ~r{["'*]}, " ") |> String.trim()

      sql = """
      SELECT rowid as chunk_id, rank
      FROM chunks_fts
      WHERE chunks_fts MATCH ?
      ORDER BY rank ASC
      LIMIT ?
      """

      case Repo.query(sql, [clean_query, limit]) do
        {:ok, %{rows: rows}} when rows != [] ->
          Enum.map(rows, fn [chunk_id, rank] -> {chunk_id, rank} end)

        _ ->
          like_search(trimmed, limit)
      end
    end
  end

  defp like_search(query_text, limit) do
    like_pattern = "%#{query_text}%"

    chunks =
      Repo.all(
        from c in Chunk,
          where: like(c.content, ^like_pattern) or like(c.heading, ^like_pattern),
          limit: ^limit,
          select: c.id
      )

    Enum.with_index(chunks, 1)
    |> Enum.map(fn {id, idx} -> {id, idx * 1.0} end)
  end

  @doc """
  Performs hybrid search combining vector and keyword search via Reciprocal Rank Fusion (RRF).
  Caps results at max 3 chunks per document.
  """
  def hybrid_search(query_text, query_embedding, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    candidate_limit = limit * 4

    vec_results =
      if query_embedding, do: vector_search(query_embedding, candidate_limit), else: []

    kw_results =
      if query_text && String.trim(query_text) != "",
        do: keyword_search(query_text, candidate_limit),
        else: []

    # Calculate RRF scores: score = 1 / (k + rank)
    vec_scores =
      vec_results
      |> Enum.with_index(1)
      |> Map.new(fn {{chunk_id, _dist}, rank} -> {chunk_id, 1.0 / (@rrf_k + rank)} end)

    kw_scores =
      kw_results
      |> Enum.with_index(1)
      |> Map.new(fn {{chunk_id, _rank}, rank} -> {chunk_id, 1.0 / (@rrf_k + rank)} end)

    all_chunk_ids = (Map.keys(vec_scores) ++ Map.keys(kw_scores)) |> Enum.uniq()

    if Enum.empty?(all_chunk_ids) do
      []
    else
      # Fetch actual chunk structs with document preloaded
      chunks =
        Repo.all(
          from c in Chunk,
            where: c.id in ^all_chunk_ids,
            preload: [:document]
        )
        |> Map.new(fn c -> {c.id, c} end)

      # Combine scores and rank
      scored_chunks =
        all_chunk_ids
        |> Enum.map(fn chunk_id ->
          chunk = Map.get(chunks, chunk_id)
          v_score = Map.get(vec_scores, chunk_id, 0.0)
          k_score = Map.get(kw_scores, chunk_id, 0.0)
          total_score = v_score + k_score
          {chunk, total_score}
        end)
        |> Enum.reject(fn {chunk, _score} -> is_nil(chunk) end)
        |> Enum.sort_by(fn {_chunk, score} -> score end, :desc)

      # Filter: max @max_chunks_per_doc per document
      {final_chunks, _counts} =
        Enum.reduce(scored_chunks, {[], %{}}, fn {chunk, score}, {acc_list, doc_counts} ->
          doc_id = chunk.document_id
          cur_count = Map.get(doc_counts, doc_id, 0)

          if cur_count < @max_chunks_per_doc and length(acc_list) < limit do
            {acc_list ++ [{chunk, score}], Map.put(doc_counts, doc_id, cur_count + 1)}
          else
            {acc_list, doc_counts}
          end
        end)

      final_chunks
    end
  end
end
