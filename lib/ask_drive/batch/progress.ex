defmodule AskDrive.Batch.Progress do
  @moduledoc """
  Progress of a running batch (spec F-340): which phase, how many of its items are done, the
  item being worked on, and a finer-grained detail within it (e.g. "埋め込み 64 / 186 チャンク"
  inside one long PDF). Written to the batch_runs row, which the admin dashboard re-reads
  every few seconds, and kept after the run ends so an aborted run shows where it stopped.

  The batch runs its phases in one process; `bind/1` remembers the run in that process so
  workers called synchronously from it (sync, chunk embedding) can report without being
  handed the run. Outside a batch (a standalone job) every call is a no-op.

  Every report is also where a stop request is honoured (spec F-341): when an admin has
  asked the run to stop, `start_phase/2`, `item/3` and `detail/1` throw `:batch_stop_requested`,
  which the scheduler catches. They are only called between items, never inside a
  transaction, so nothing is left half-written; the item being worked on is picked up again
  by the next batch.
  """

  import Ecto.Query, warn: false
  alias AskDrive.Batch.{BatchPhaseStat, BatchRun}
  alias AskDrive.Repo

  @key {__MODULE__, :run_id}

  # Phases in order, with their share of the overall percentage when there is no history to
  # estimate times from (the first runs). Generation dominates a full batch; embedding the
  # chunks dominates an ingest-only one. Rough by nature: shown as 目安.
  @full [
    {"sync", 10},
    {"invalidate", 1},
    {"embed_chunks", 35},
    {"generate", 50},
    {"embed_questions", 3},
    {"verify", 1}
  ]
  @ingest_only [{"sync", 20}, {"invalidate", 2}, {"embed_chunks", 76}, {"verify", 2}]

  @labels %{
    "sync" => "Drive の一覧を同期",
    "invalidate" => "変更の反映",
    "embed_chunks" => "取り込み（本文抽出・分割・埋め込み）",
    "generate" => "想定QAの生成",
    "embed_questions" => "想定質問の埋め込み",
    "verify" => "仕上げ（未回答の解消）"
  }

  def label(phase), do: Map.get(@labels, phase, phase)

  def bind(run_id), do: Process.put(@key, run_id)
  def unbind, do: Process.delete(@key)
  def current_run_id, do: Process.get(@key)

  @doc "Enters `phase` with `total` items to go through."
  def start_phase(phase, total) do
    check_stop(:ok)

    update(%{
      progress_phase: phase,
      progress_done: 0,
      progress_total: total,
      progress_item: nil,
      progress_detail: nil,
      progress_phase_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc "Now working on item number `done + 1` (`item` is its name); `extra` = more run fields."
  def item(done, item, extra \\ %{}) do
    update(Map.merge(%{progress_done: done, progress_item: item, progress_detail: nil}, extra))
    |> check_stop()
  end

  @doc "`done` items finished (the phase's last one included)."
  def done(done, extra \\ %{}), do: update(Map.merge(%{progress_done: done}, extra))

  @doc "What is happening inside the current item (nil clears it)."
  def detail(text), do: update(%{progress_detail: text}) |> check_stop()

  defp check_stop(:ok) do
    with run_id when not is_nil(run_id) <- current_run_id(),
         %DateTime{} <-
           Repo.one(from b in BatchRun, where: b.id == ^run_id, select: b.stop_requested_at) do
      throw(:batch_stop_requested)
    end

    :ok
  end

  defp update(attrs) do
    case current_run_id() do
      nil ->
        :ok

      run_id ->
        attrs =
          if Map.has_key?(attrs, :progress_item),
            do: Map.update!(attrs, :progress_item, &truncate/1),
            else: attrs

        Repo.update_all(from(b in BatchRun, where: b.id == ^run_id), set: Map.to_list(attrs))
        :ok
    end
  end

  defp truncate(nil), do: nil
  defp truncate(s) when is_binary(s), do: String.slice(s, 0, 255)

  # recent runs a phase's time is estimated from
  @history_runs 5

  @doc """
  How long each phase took in the last few runs of `kind` (F-354), for estimating the time
  left: `%{phase => %{median: seconds, rate: seconds per item | nil}}`. Phases cut off by a
  stop or a crash aren't recorded, so only finished phases count.
  """
  def phase_history(kind) do
    from(s in BatchPhaseStat,
      join: b in BatchRun,
      on: b.id == s.batch_run_id,
      where: b.kind == ^kind and s.status == "completed",
      order_by: [desc: s.id],
      limit: ^(@history_runs * 12),
      select: {s.phase_name, s.duration_seconds, s.items_count}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
    |> Map.new(fn {phase, stats} ->
      stats = Enum.take(stats, @history_runs)
      durations = stats |> Enum.map(&(elem(&1, 0) || 0)) |> Enum.sort()
      counted = Enum.filter(stats, fn {_d, n} -> (n || 0) > 0 end)
      items = counted |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      rate =
        if items > 0,
          do: (counted |> Enum.map(&(elem(&1, 0) || 0)) |> Enum.sum()) / items

      {phase, %{median: Enum.at(durations, div(length(durations), 2)), rate: rate}}
    end)
  end

  @doc """
  What to show for `run`: step n of m, the phase and its fraction, an overall percentage,
  and the estimated time left in the phase from its pace so far. nil when the run hasn't
  reported progress (runs from before F-340).

  The overall percentage is by time (F-354): the time spent so far over that plus the time
  expected to be left — the current phase's from its pace (or from earlier runs' time per
  item before its first item is done), each later phase's from how long it took in recent
  runs (`opts[:history]`, see `phase_history/1`), and QA generation no later than the
  cut-off (`opts[:deadline]`). Without history for a phase it falls back to the fixed
  weights per phase (`basis: :weights`).
  """
  def overview(run, now \\ DateTime.utc_now(), opts \\ [])
  def overview(%BatchRun{progress_phase: nil}, _now, _opts), do: nil

  def overview(%BatchRun{} = run, now, opts) do
    phases = if run.kind == "ingest_only", do: @ingest_only, else: @full
    index = Enum.find_index(phases, fn {p, _} -> p == run.progress_phase end) || 0
    total_weight = phases |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    before = phases |> Enum.take(index) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    {_, weight} = Enum.at(phases, index)

    done = run.progress_done || 0
    total = run.progress_total || 0
    fraction = if total > 0, do: min(done / total, 1.0), else: 0.0
    finished? = run.status != "running"

    elapsed =
      if run.progress_phase_started_at,
        do: max(DateTime.diff(now, run.progress_phase_started_at), 0),
        else: 0

    eta = if not finished? and done > 0 and total > done, do: div(elapsed * (total - done), done)

    remaining =
      if not finished? and run.started_at,
        do:
          time_left(
            run,
            phases,
            index,
            %{done: done, total: total, elapsed: elapsed, eta: eta},
            now,
            opts
          )

    overall =
      cond do
        finished? and run.status == "completed" ->
          100

        is_integer(remaining) ->
          spent = max(DateTime.diff(now, run.started_at), 0)
          # never 100 while it still runs
          if spent + remaining > 0, do: min(trunc(spent * 100 / (spent + remaining)), 99), else: 0

        true ->
          trunc((before + weight * fraction) * 100 / total_weight)
      end

    %{
      step: index + 1,
      steps: length(phases),
      phase: run.progress_phase,
      label: label(run.progress_phase),
      done: done,
      total: total,
      percent: trunc(fraction * 100),
      overall: min(overall, 100),
      item: run.progress_item,
      detail: run.progress_detail,
      elapsed_seconds: elapsed,
      eta_seconds: eta,
      remaining_seconds: remaining,
      basis: if(is_integer(remaining), do: :time, else: :weights)
    }
  end

  # Seconds the run is expected to take from now, or nil when a phase has nothing to go by
  defp time_left(run, phases, index, current, now, opts) do
    history = Keyword.get(opts, :history, %{})
    deadline = Keyword.get(opts, :deadline)

    # QA generation stops at the cut-off, however much is left (only a full batch generates)
    until_deadline =
      if deadline && run.kind != "ingest_only", do: max(DateTime.diff(deadline, now), 0)

    cap = fn
      "generate", secs, spent when is_integer(secs) and is_integer(until_deadline) ->
        min(secs, max(until_deadline - spent, 0))

      _phase, secs, _spent ->
        secs
    end

    {phase, _} = Enum.at(phases, index)
    now_left = cap.(phase, current_left(phase, current, history), 0)

    phases
    |> Enum.drop(index + 1)
    |> Enum.reduce_while(now_left, fn
      _, nil ->
        {:halt, nil}

      {later, _}, acc ->
        case history[later] do
          %{median: secs} when is_integer(secs) -> {:cont, acc + cap.(later, secs, acc)}
          _ -> {:halt, nil}
        end
    end)
  end

  defp current_left(phase, %{done: done, total: total, elapsed: elapsed, eta: eta}, history) do
    cond do
      total > 0 and done >= total ->
        0

      is_integer(eta) ->
        eta

      total > 0 and is_number(history[phase][:rate]) ->
        max(round(history[phase].rate * total) - elapsed, 0)

      is_integer(history[phase][:median]) ->
        max(history[phase].median - elapsed, 0)

      true ->
        nil
    end
  end
end
