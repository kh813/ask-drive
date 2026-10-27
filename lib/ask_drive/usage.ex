defmodule AskDrive.Usage do
  @moduledoc """
  Who uses the desks, and what is asked often: the 「利用状況」 tabs of a desk's admin screen
  (spec F-1415) and of the platform's (F-1416).

  Each question asked in the chat leaves a `QuestionUsage` row: the asker, how it was
  answered and the tokens answering it used. The API usage log stays free of who asked
  (N-606); the tokens are counted here as the calls are made (`collect/1`). Rows are kept for
  90 days.

  Privacy: the per-person figures are counts only — nothing here ties a person to the text
  of what they asked. 「よくある質問」 comes from the question log, which has no asker, and
  only shows questions asked at least twice, so one person's one-off question (about
  their own circumstances) never appears there.
  """
  import Ecto.Query, warn: false

  require Logger

  alias AskDrive.{Answering, Apps, Repo}
  alias AskDrive.Accounts.User
  alias AskDrive.QA.QuestionLog
  alias AskDrive.Usage.QuestionUsage

  @retention_days 90
  @periods [7, 30, 90]
  @frequent_min 2
  @tokens_key {__MODULE__, :tokens}

  @doc "The periods (days) the tabs can show."
  def periods, do: @periods

  @doc "How long the rows are kept (days)."
  def retention_days, do: @retention_days

  @doc "How often a question has to be asked to show in 「よくある質問」."
  def frequent_min, do: @frequent_min

  @doc "A period from the screen (`\"30\"`), one of `periods/0`; 30 otherwise."
  def period(value) do
    case Integer.parse(to_string(value)) do
      {days, ""} when days in @periods -> days
      _ -> 30
    end
  end

  # --- Recording -------------------------------------------------------------------

  @doc """
  Runs `fun`, counting the tokens of the API calls it makes in this process
  (`AskDrive.Metrics.record/1` reports them). Returns `{result, tokens}`.
  """
  def collect(fun) when is_function(fun, 0) do
    previous = Process.put(@tokens_key, 0)

    try do
      result = fun.()
      {result, Process.get(@tokens_key, 0)}
    after
      if previous, do: Process.put(@tokens_key, previous), else: Process.delete(@tokens_key)
    end
  end

  @doc false
  # called by Metrics.record/1 for every API call: counted only inside collect/1
  def count_tokens(tokens) when is_integer(tokens) do
    case Process.get(@tokens_key) do
      nil -> :ok
      sum -> Process.put(@tokens_key, sum + tokens)
    end

    :ok
  end

  def count_tokens(_), do: :ok

  @doc """
  Answers a chat question with `answer` (returning `Answering.ask/2`'s result) and records it
  for `user`, with the tokens it used. The result gets the row's id as `:usage_id`, for the
  AI summary's tokens (`add_tokens/2`).
  """
  def track_question(user, follow_up?, answer) when is_function(answer, 0) do
    {result, tokens} = collect(answer)

    attrs = %{
      user_id: user_id(user),
      question_log_id: Map.get(result, :question_log_id),
      tier: Map.get(result, :tier),
      follow_up: follow_up?,
      tokens: tokens,
      asked_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Map.put(result, :usage_id, insert(attrs))
  end

  # the answer matters more than its record: never fail the question over it
  defp insert(attrs) do
    case %QuestionUsage{} |> QuestionUsage.changeset(attrs) |> Repo.insert() do
      {:ok, %{id: id}} -> id
      {:error, _} -> nil
    end
  rescue
    e ->
      Logger.warning("Usage: could not record a question: #{Exception.message(e)}")
      nil
  end

  @doc "Runs `fun` (the AI summary) and adds the tokens it used to the question `usage_id`."
  def track_tokens(usage_id, fun) when is_function(fun, 0) do
    {result, tokens} = collect(fun)
    add_tokens(usage_id, tokens)
    result
  end

  @doc "Adds `tokens` to the question `usage_id`."
  def add_tokens(nil, _tokens), do: :ok
  def add_tokens(_usage_id, 0), do: :ok

  def add_tokens(usage_id, tokens) do
    Repo.update_all(from(u in QuestionUsage, where: u.id == ^usage_id), inc: [tokens: tokens])
    :ok
  rescue
    e -> Logger.warning("Usage: could not add the summary's tokens: #{Exception.message(e)}")
  end

  defp user_id(%{id: id}) when is_integer(id), do: id
  defp user_id(_), do: 0

  @doc """
  Deletes the rows older than `days` (default #{@retention_days}) from the current desk; the
  nightly batch calls it for each desk.
  """
  def prune(days \\ @retention_days, now \\ DateTime.utc_now()) do
    before = DateTime.add(now, -days * 86_400, :second)
    {count, _} = Repo.delete_all(from u in QuestionUsage, where: u.asked_at < ^before)
    count
  end

  # --- A desk's 「利用状況」 (F-1415) --------------------------------------------------

  @doc """
  The current desk's last `days`: `%{days:, questions:, tokens:, users:, people:, frequent:}`.
  `people` are the askers, most questions first (or most tokens, with `sort: :tokens`).
  """
  def desk_report(days, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    rows = desk_people(days, now)
    users = users_by_id(Enum.map(rows, & &1.user_id))
    people = rows |> Enum.map(&put_person(&1, users)) |> sort_people(opts[:sort])

    %{
      days: days,
      questions: Enum.sum_by(rows, & &1.questions),
      tokens: Enum.sum_by(rows, & &1.tokens),
      users: Enum.count(rows, &(&1.user_id > 0)),
      people: Enum.take(people, Keyword.get(opts, :limit, 50)),
      frequent: frequent_questions(days, now: now)
    }
  end

  # per asker: questions, tokens, how many were solved, the last one
  defp desk_people(days, now) do
    since = DateTime.add(now, -days * 86_400, :second)

    Repo.all(
      from u in QuestionUsage,
        left_join: q in QuestionLog,
        on: q.id == u.question_log_id,
        where: u.asked_at >= ^since,
        group_by: u.user_id,
        select: %{
          user_id: u.user_id,
          questions: count(u.id),
          tokens: coalesce(sum(u.tokens), 0),
          # solved as on the 「API利用量・ログ」 tab (F-1413): answered from a QA pair and
          # not followed up, given one later, or marked 「解決した」 by the asker
          solved:
            count(
              fragment(
                "CASE WHEN (? IN (0, 1) AND ? IS NULL) OR ? IS NOT NULL OR ? IS NOT NULL THEN 1 END",
                q.tier_reached,
                q.followed_up_at,
                q.resolved_at,
                q.user_solved_at
              )
            ),
          last_at: max(u.asked_at)
        }
    )
  end

  @doc """
  The questions asked at least #{@frequent_min} times in the last `days` (new questions,
  not follow-ups), by their wording as the exact-match cache compares it (`Answering.normalize_question/1`), spaces
  aside:
  `[%{question:, count:, solved:, last_at:}]`, most asked first.
  """
  def frequent_questions(days, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -days * 86_400, :second)

    Repo.all(
      from q in QuestionLog,
        where: q.asked_at >= ^since and not q.follow_up,
        order_by: [desc: q.asked_at, desc: q.id],
        select: %{
          question: q.question,
          asked_at: q.asked_at,
          solved:
            fragment(
              "CASE WHEN (? IN (0, 1) AND ? IS NULL) OR ? IS NOT NULL OR ? IS NOT NULL THEN 1 ELSE 0 END",
              q.tier_reached,
              q.followed_up_at,
              q.resolved_at,
              q.user_solved_at
            )
        }
    )
    |> Enum.group_by(&wording/1)
    |> Enum.reject(fn {key, logs} -> key == "" or length(logs) < @frequent_min end)
    |> Enum.map(fn {_key, [latest | _] = logs} ->
      %{
        # the latest wording
        question: latest.question,
        count: length(logs),
        solved: Enum.count(logs, &(&1.solved == 1)),
        last_at: latest.asked_at
      }
    end)
    |> Enum.sort_by(&{-&1.count, -DateTime.to_unix(&1.last_at)})
    |> Enum.take(Keyword.get(opts, :limit, 30))
  end

  # as the exact-match cache compares, and without spaces (「有給の 申請」 is 「有給の申請」)
  defp wording(%{question: question}),
    do: question |> Answering.normalize_question() |> String.replace(" ", "")

  # --- The platform's 「利用状況」 (F-1416) --------------------------------------------

  @doc """
  Every desk's last `days`, added up per person: `%{days:, questions:, tokens:, users:,
  desks:, people:}`. Each person has their total, the number of desks they used and
  `desks: [%{app:, questions:, tokens:}]`, the biggest first.
  """
  def platform_report(days, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    per_desk =
      Apps.each(fn _app -> desk_people(days, now) end)
      |> Enum.flat_map(fn {app, rows} -> Enum.map(rows, &Map.put(&1, :app, app)) end)

    users = users_by_id(Enum.map(per_desk, & &1.user_id))

    people =
      per_desk
      |> Enum.group_by(& &1.user_id)
      |> Enum.map(fn {user_id, rows} ->
        desks =
          rows
          |> Enum.map(&Map.take(&1, [:app, :questions, :tokens]))
          |> Enum.sort_by(&{-&1.questions, -&1.tokens})

        put_person(
          %{
            user_id: user_id,
            questions: Enum.sum_by(rows, & &1.questions),
            tokens: Enum.sum_by(rows, & &1.tokens),
            solved: Enum.sum_by(rows, & &1.solved),
            last_at: rows |> Enum.map(& &1.last_at) |> Enum.max(DateTime),
            desks: desks
          },
          users
        )
      end)
      |> sort_people(opts[:sort])

    %{
      days: days,
      questions: Enum.sum_by(people, & &1.questions),
      tokens: Enum.sum_by(people, & &1.tokens),
      users: Enum.count(people, &(&1.user_id > 0)),
      desks: per_desk |> Enum.map(& &1.app.slug) |> Enum.uniq() |> length(),
      people: Enum.take(people, Keyword.get(opts, :limit, 100))
    }
  end

  # --- Shared ------------------------------------------------------------------------

  defp users_by_id(ids) do
    ids = ids |> Enum.filter(&(&1 > 0)) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Apps.platform(fn -> Repo.all(from u in User, where: u.id in ^ids) end)
      |> Map.new(&{&1.id, &1})
    end
  end

  # who: a user, the guest (sign-in off), or one deleted since
  defp put_person(row, users) do
    kind =
      cond do
        row.user_id == 0 -> :guest
        Map.has_key?(users, row.user_id) -> :user
        true -> :deleted
      end

    user = users[row.user_id]

    row
    |> Map.put(:kind, kind)
    |> Map.put(:email, user && user.email)
    |> Map.put(:name, user && User.display_name(user))
    |> Map.put(:solved_rate, if(row.questions > 0, do: round(row.solved / row.questions * 100)))
  end

  defp sort_people(people, :tokens),
    do: Enum.sort_by(people, &{-&1.tokens, -&1.questions, &1.user_id})

  defp sort_people(people, _questions),
    do: Enum.sort_by(people, &{-&1.questions, -&1.tokens, &1.user_id})
end
