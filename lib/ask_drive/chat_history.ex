defmodule AskDrive.ChatHistory do
  @moduledoc """
  Each signed-in user's chat history in a desk (spec F-430): the questions they asked and the
  answers they got, so they can look an answer up again instead of asking once more.

  Kept in the desk's own database, per user; only that user lists, opens or deletes it. The
  shared guest of a desk without login (id 0) has no history: everyone would see everyone's.

  An entry keeps the answer text and the AI summary as they were shown, and points at the QA
  pair and the excerpts by id. Opening it shows them again; when a document has been
  re-indexed since, its excerpts no longer exist and the entry's saved list of sources
  (document, page, link) is shown instead.
  """
  import Ecto.Query, warn: false

  alias AskDrive.ChatHistory.Entry
  alias AskDrive.Documents.Chunk
  alias AskDrive.QA.QAPair
  alias AskDrive.Repo

  @list_limit 50

  @doc "Whether `user` keeps a history (anyone signed in; not the shared guest)."
  def enabled?(%{id: id}) when is_integer(id) and id > 0, do: true
  def enabled?(_user), do: false

  @doc """
  Saves an answer (`Answering.ask/1`'s result) to `user`'s history, in the thread `thread_key`
  (F-431); nil if the user keeps none.
  """
  def record(user, result, thread_key \\ nil) do
    if enabled?(user) do
      chunks = result.chunks || []

      %Entry{user_id: user.id, thread_key: thread_key || Ecto.UUID.generate()}
      |> Entry.changeset(%{
        question: result.question,
        tier: result.tier,
        answer: if(result.tier in [0, 1], do: result.answer),
        qa_pair_id: result.qa_pair && result.qa_pair.id,
        chunk_ids: if(result.tier == 2, do: Enum.map(chunks, & &1.id), else: []),
        sources: if(result.tier == 2, do: Enum.map(chunks, &source/1), else: []),
        index_empty: Map.get(result, :index_empty?, false),
        asked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()
      |> case do
        {:ok, entry} -> entry
        {:error, _} -> nil
      end
    end
  end

  defp source(%Chunk{} = chunk) do
    document = if Ecto.assoc_loaded?(chunk.document), do: chunk.document

    %{
      "name" => document && document.name,
      "page" => chunk.page,
      "link" => document && document.web_view_link
    }
  end

  @doc "Keeps the AI summary as it was shown (finished, or as far as it got when stopped)."
  def put_summary(nil, _text), do: :ok
  def put_summary(_entry_id, ""), do: :ok

  def put_summary(entry_id, text) do
    Repo.update_all(from(e in Entry, where: e.id == ^entry_id), set: [summary: text])
    :ok
  end

  @doc """
  `user`'s threads (F-431), the latest first: `%{id: thread_key, title: its first question,
  follow_ups: how many, tier: the first answer's, asked_at: the latest question's}`. `query`
  narrows them to threads with a question containing it.
  """
  def list(user, query \\ "") do
    if enabled?(user) do
      query = String.trim(query || "")

      keys =
        from(e in Entry,
          where: e.user_id == ^user.id,
          group_by: e.thread_key,
          order_by: [desc: max(e.asked_at), desc: max(e.id)],
          limit: @list_limit,
          select: e.thread_key
        )
        |> then(fn q ->
          if query == "",
            do: q,
            else: where(q, [e], like(e.question, ^"%#{escape_like(query)}%"))
        end)
        |> Repo.all()

      entries =
        Repo.all(
          from e in Entry,
            where: e.user_id == ^user.id and e.thread_key in ^keys,
            order_by: [asc: e.asked_at, asc: e.id]
        )
        |> Enum.group_by(& &1.thread_key)

      Enum.flat_map(keys, fn key ->
        case entries[key] do
          [first | _] = thread ->
            [
              %{
                id: key,
                title: first.question,
                follow_ups: length(thread) - 1,
                tier: first.tier,
                asked_at: List.last(thread).asked_at
              }
            ]

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  # SQLite's LIKE has no escape character by default: match % and _ literally by dropping them
  defp escape_like(text), do: String.replace(text, ["%", "_"], "")

  @doc "One of `user`'s threads: its entries, the first question first ([] if none)."
  def get_thread(user, key) do
    if enabled?(user) do
      Repo.all(
        from e in Entry,
          where: e.user_id == ^user.id and e.thread_key == ^key,
          order_by: [asc: e.asked_at, asc: e.id]
      )
    else
      []
    end
  end

  @doc "Deletes one of `user`'s threads (its question and every follow-up)."
  def delete_thread(user, key) do
    if enabled?(user) do
      case Repo.delete_all(from e in Entry, where: e.user_id == ^user.id and e.thread_key == ^key) do
        {0, _} -> {:error, :not_found}
        {n, _} -> {:ok, n}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  What the chat needs to show `entry` again: the QA pair and the excerpts it pointed at, with
  their documents. `chunks` is [] when any excerpt is gone (re-indexed), since the summary's
  [n] citations count on all of them; `sources` then lists what they were.
  """
  def restore(%Entry{} = entry) do
    qa_pair =
      entry.qa_pair_id &&
        Repo.one(from q in QAPair, where: q.id == ^entry.qa_pair_id, preload: [:document])

    ids = entry.chunk_ids || []

    found =
      if ids == [],
        do: %{},
        else:
          Repo.all(from c in Chunk, where: c.id in ^ids, preload: [:document])
          |> Map.new(&{&1.id, &1})

    chunks =
      if Enum.all?(ids, &Map.has_key?(found, &1)), do: Enum.map(ids, &found[&1]), else: []

    %{qa_pair: qa_pair, chunks: chunks, sources: entry.sources || []}
  end
end
