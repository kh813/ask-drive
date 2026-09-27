defmodule AskDrive.Answering do
  @moduledoc """
  Core query pipeline that routes questions through Tier 0 (exact cache), Tier 1 (generated QA),
  Tier 2 (raw chunk excerpt), and Tier 3 (unanswered log for nightly generation).
  """
  alias AskDrive.QA.QuestionLog
  alias AskDrive.Repo
  alias AskDrive.Retrieval
  alias AskDrive.Settings
  alias AskDrive.Vector
  alias AskDrive.LLM.Ollama

  @doc """
  Processes a user question and returns a structured response map with tier information and sources.
  """
  def ask(question, _opts \\ []) when is_binary(question) do
    trimmed = String.trim(question)
    setting = Settings.get_setting!()
    now = DateTime.utc_now()

    # 1. Generate query embedding via bge-m3
    embedding =
      case Ollama.embed(setting.embed_model, [trimmed]) do
        {:ok, [vec | _]} -> vec
        _ -> nil
      end

    # 2. Tier 2 Hybrid Search (vec_chunks + chunks_fts trigram)
    scored_chunks = Retrieval.hybrid_search(trimmed, embedding, limit: 3)

    {tier, matched_chunks} =
      if Enum.empty?(scored_chunks) do
        {3, []}
      else
        chunks = Enum.map(scored_chunks, fn {chunk, _score} -> chunk end)
        {2, chunks}
      end

    # 3. Record in question_log table for nightly resolution loop
    candidate_ids = Enum.map(matched_chunks, & &1.id)
    embedding_blob = if embedding, do: Vector.encode(embedding), else: nil

    _ =
      %QuestionLog{}
      |> QuestionLog.changeset(%{
        question: trimmed,
        question_embedding: embedding_blob,
        tier_reached: tier,
        candidate_chunk_ids: candidate_ids,
        asked_at: now
      })
      |> Repo.insert()

    %{
      tier: tier,
      question: trimmed,
      answer: nil,
      chunks: matched_chunks,
      qa_pair: nil,
      asked_at: now
    }
  end
end
