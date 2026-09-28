defmodule AskDrive.Answering do
  @moduledoc """
  Core query pipeline that routes questions through Tier 0 (exact cache), Tier 1 (generated QA),
  Tier 2 (raw chunk excerpt), and Tier 3 (unanswered log for nightly generation).

  Execution hierarchy:
  1. Tier 0: Normalized string exact match in `answer_cache` (Instant, 0 vector calculations).
  2. Tier 1: Vector search on `vec_qa_pairs` (threshold >= tier1_threshold, default 0.90).
     If found, stores into `answer_cache` for future instant Tier 0 hits.
  3. Tier 2: Hybrid search on `vec_chunks` + `chunks_fts` (RRF fusion, raw excerpts, no LLM).
  4. Tier 3: Unanswered. Logged into `question_log` for resolution in nightly batch.
  """
  alias AskDrive.QA
  alias AskDrive.QA.QuestionLog
  alias AskDrive.Repo
  alias AskDrive.Retrieval
  alias AskDrive.Settings
  alias AskDrive.Vector
  alias AskDrive.LLM

  require Logger

  @query_embed_timeout 10_000

  @doc """
  Processes a user question and returns a structured response map with tier information and sources.
  """
  def ask(question, _opts \\ []) when is_binary(question) do
    trimmed = String.trim(question)
    normalized = normalize_question(trimmed)
    setting = Settings.get_setting!()
    now = DateTime.utc_now()

    # --- Tier 0: Answer Cache exact match ---
    tier0_result =
      if Map.get(setting, :tier0_enabled, true) do
        QA.get_cached_answer(normalized)
      else
        nil
      end

    if tier0_result &&
         (tier0_result.status == "active" ||
            (tier0_result.status == "stale" && setting.serve_stale_qa)) do
      record_question_log(trimmed, nil, 0, [tier0_result.chunk_id], now)

      %{
        tier: 0,
        question: trimmed,
        answer: tier0_result.answer,
        chunks: [tier0_result.chunk] |> Enum.reject(&is_nil/1),
        qa_pair: tier0_result,
        asked_at: now
      }
    else
      # Not found in Tier 0. Generate query embedding for Tier 1 / Tier 2.
      #
      # Short and without retries: while a batch holds the local model (e.g. a manual batch
      # generating QA in the daytime) the embedding request queues behind generation, and the
      # default 30s x 3 attempts left the chat hanging for minutes. Giving up quickly lets
      # Tier 2 answer from keyword search alone instead.
      embedding =
        case LLM.embed(setting.embed_model, [trimmed],
               setting: setting,
               timeout: @query_embed_timeout,
               retry: false
             ) do
          {:ok, [vec | _]} ->
            vec

          other ->
            Logger.warning(
              "Answering: query embedding unavailable (#{inspect(other)}); keyword search only"
            )

            nil
        end

      # --- Tier 1: Vector Search on Hypothetical QA pairs ---
      # Its own setting (default 0.90). This used to read a field that didn't exist and fall
      # back to similarity_threshold (0.65), answering loosely related questions with a
      # canned QA instead of letting them reach the excerpts and the AI summary.
      tier1_threshold = setting.tier1_threshold || 0.90

      tier1_match =
        if embedding do
          case QA.search_qa_vectors(embedding, 3) do
            [{best_qa, sim} | _] when sim >= tier1_threshold ->
              if best_qa.status == "active" or
                   (best_qa.status == "stale" and setting.serve_stale_qa) do
                # Update answer cache for future Tier 0 instant hit
                if Map.get(setting, :tier0_enabled, true) do
                  QA.put_cached_answer(normalized, best_qa.id)
                end

                {best_qa, sim}
              else
                nil
              end

            _ ->
              nil
          end
        else
          nil
        end

      if tier1_match do
        {matched_qa, _sim} = tier1_match
        candidate_ids = if matched_qa.chunk_id, do: [matched_qa.chunk_id], else: []
        record_question_log(trimmed, embedding, 1, candidate_ids, now)

        %{
          tier: 1,
          question: trimmed,
          answer: matched_qa.answer,
          chunks: [matched_qa.chunk] |> Enum.reject(&is_nil/1),
          qa_pair: matched_qa,
          asked_at: now
        }
      else
        # --- Tier 2: Hybrid Search on Raw Document Chunks (RRF) ---
        tier2_enabled = Map.get(setting, :tier2_enabled, true)
        excerpt_count = Map.get(setting, :tier2_excerpt_count, 3)

        scored_chunks =
          if tier2_enabled do
            Retrieval.hybrid_search(trimmed, embedding, limit: excerpt_count)
          else
            []
          end

        {tier, matched_chunks} =
          if Enum.empty?(scored_chunks) do
            {3, []}
          else
            chunks = Enum.map(scored_chunks, fn {chunk, _score} -> chunk end)
            {2, chunks}
          end

        # --- Tier 2 / 3: Record question in question_log table ---
        candidate_ids = Enum.map(matched_chunks, & &1.id)
        record_question_log(trimmed, embedding, tier, candidate_ids, now)

        %{
          tier: tier,
          question: trimmed,
          answer: nil,
          chunks: matched_chunks,
          qa_pair: nil,
          asked_at: now,
          # Tier 2 has no similarity floor, so Tier 3 almost always means nothing is indexed
          # yet (e.g. Drive sync failing) — a different message than "no good match".
          index_empty?: tier == 3 and not Repo.exists?(AskDrive.Documents.Chunk)
        }
      end
    end
  end

  @doc """
  Normalizes question text:
  - Trims leading/trailing whitespace
  - Collapses internal whitespace
  - Lowercases alphabetic characters
  - Converts full-width alphanumeric to half-width
  - Normalizes Japanese punctuation/symbols
  """
  def normalize_question(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.downcase()
    |> to_halfwidth()
    |> String.replace(~r/[？\?！\!。、,.\s]+/u, " ")
    |> String.trim()
  end

  defp to_halfwidth(str) do
    # Convert full-width ASCII (0xFF01..0xFF5E) to half-width (0x21..0x7E)
    # Convert full-width space (0x3000) to standard space (0x20)
    str
    |> String.to_charlist()
    |> Enum.map(fn
      0x3000 -> ?\s
      ch when ch in 0xFF01..0xFF5E -> ch - 0xFEE0
      ch -> ch
    end)
    |> List.to_string()
  end

  defp record_question_log(question, embedding, tier, candidate_ids, now) do
    embedding_blob = if embedding, do: Vector.encode(embedding), else: nil

    %QuestionLog{}
    |> QuestionLog.changeset(%{
      question: question,
      question_embedding: embedding_blob,
      tier_reached: tier,
      candidate_chunk_ids: candidate_ids,
      asked_at: now
    })
    |> Repo.insert()
  end
end
