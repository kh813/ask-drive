defmodule AskDrive.QA do
  @moduledoc """
  Context for managing generated Q&A pairs, answer caching, and question logs.
  """
  import Ecto.Query, warn: false
  alias AskDrive.Repo
  alias AskDrive.QA.{AnswerCache, QAPair, QuestionLog}
  alias AskDrive.Vector

  @doc """
  Lists QA pairs for a given document.
  """
  def list_qa_pairs_for_document(document_id) do
    Repo.all(
      from q in QAPair,
        where: q.document_id == ^document_id,
        order_by: [desc: q.inserted_at]
    )
  end

  @doc """
  Lists all active QA pairs with document preloaded.
  """
  def list_active_qa_pairs do
    Repo.all(
      from q in QAPair,
        where: q.status == "active",
        preload: [:document, :chunk],
        order_by: [desc: q.hit_count]
    )
  end

  @doc """
  Creates a single QA pair record.
  """
  def create_qa_pair(attrs) do
    %QAPair{}
    |> QAPair.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Saves a QA pair along with its question embedding into both PostgreSQL/SQLite tables
  and the `vec_qa_pairs` virtual table in a single transaction.
  """
  def save_qa_pair_with_embedding(attrs, embedding_floats) when is_list(embedding_floats) do
    blob = Vector.encode(embedding_floats)
    json_vec = Vector.to_json(embedding_floats)

    Repo.transaction(fn ->
      {:ok, qa} =
        %QAPair{}
        |> QAPair.changeset(Map.put(attrs, :question_embedding, blob))
        |> Repo.insert()

      Repo.query!(
        "INSERT INTO vec_qa_pairs(qa_pair_id, question_embedding) VALUES (?, ?)",
        [qa.id, json_vec]
      )

      qa
    end)
  end

  @doc """
  Marks QA pairs of a document as stale when the underlying document content changes.
  """
  def mark_stale_by_document(document_id) do
    query = from q in QAPair, where: q.document_id == ^document_id and q.status == "active"
    Repo.update_all(query, set: [status: "stale"])
  end

  @doc """
  Vector search on `vec_qa_pairs` (Tier 1 search).
  """
  def search_qa_vectors(query_embedding, limit \\ 5) when is_list(query_embedding) do
    json_vec = Vector.to_json(query_embedding)

    sql = """
    SELECT qa_pair_id, distance
    FROM vec_qa_pairs
    WHERE question_embedding MATCH ? AND k = ?
    ORDER BY distance ASC
    """

    case Repo.query(sql, [json_vec, limit]) do
      {:ok, %{rows: rows}} ->
        qa_ids = Enum.map(rows, fn [id, _d] -> id end)
        dist_map = Map.new(rows, fn [id, d] -> {id, d} end)

        qas =
          Repo.all(
            from q in QAPair,
              where: q.id in ^qa_ids and q.status == "active",
              preload: [:document, :chunk]
          )

        Enum.map(qas, fn q ->
          dist = Map.get(dist_map, q.id, 1.0)
          similarity = 1.0 - dist
          {q, similarity}
        end)
        |> Enum.sort_by(fn {_q, sim} -> sim end, :desc)

      _ ->
        []
    end
  end

  @doc """
  Searches the Tier 0 exact match answer cache.
  """
  def get_cached_answer(normalized_question) do
    case Repo.one(
           from c in AnswerCache,
             where: c.normalized_question == ^normalized_question,
             preload: [qa_pair: [:document]]
         ) do
      nil ->
        nil

      %AnswerCache{} = cache ->
        # Increment hit count
        cache
        |> AnswerCache.changeset(%{
          hit_count: cache.hit_count + 1,
          last_hit_at: DateTime.utc_now()
        })
        |> Repo.update()

        cache.qa_pair
    end
  end

  @doc """
  Stores or updates a Tier 0 cache entry.
  """
  def put_cached_answer(normalized_question, qa_pair_id) do
    case Repo.get_by(AnswerCache, normalized_question: normalized_question) do
      nil ->
        %AnswerCache{}
        |> AnswerCache.changeset(%{
          normalized_question: normalized_question,
          qa_pair_id: qa_pair_id,
          hit_count: 1,
          last_hit_at: DateTime.utc_now()
        })
        |> Repo.insert()

      existing ->
        existing
        |> AnswerCache.changeset(%{
          qa_pair_id: qa_pair_id,
          last_hit_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  @doc """
  Lists unresolved Tier 2 / 3 questions from question_log.
  """
  def list_unresolved_questions do
    Repo.all(
      from q in QuestionLog,
        where: is_nil(q.resolved_at) and q.tier_reached in [2, 3],
        order_by: [desc: q.asked_at],
        limit: 50
    )
  end

  @doc """
  Lists recently resolved questions from question_log.
  """
  def list_resolved_questions do
    Repo.all(
      from q in QuestionLog,
        where: not is_nil(q.resolved_at),
        preload: [resolved_qa: [:document]],
        order_by: [desc: q.resolved_at],
        limit: 50
    )
  end
end
