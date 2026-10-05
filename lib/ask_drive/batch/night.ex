defmodule AskDrive.Batch.Night do
  @moduledoc """
  The nightly batch across desks (spec F-355). The desks share one local model, so they run
  one at a time (F-1107), in two passes:

    1. **Import** (sync, invalidate, embed: phases 1-3) for every desk, the least imported
       first (share of its documents indexed; a desk with none yet goes first). A document
       that isn't imported can't even be found by search, and importing is the shorter part.
       Each run is then left "waiting".
    2. **Generate** (QA generation, then phases 5-6) for the waiting desks, the least
       covered first (share of its chunks that need no more generation). The time left until
       the night's cut-off is shared between them in proportion to the chunks each still has
       to generate, recomputed as each desk finishes, so time one doesn't use goes to the
       next — no desk can take the whole night and leave the others none.

  The cut-off is fixed once, at the start of the night: a desk whose turn comes after it
  generates nothing (it used to compute its own cut-off when it started, and one starting
  after 08:00 got the next morning's).

  While it goes through the desks this process is registered under this module's name, so
  `Scheduler.running_anywhere?/0` holds (no manual run starts in between, and the night
  window doesn't start a second one).
  """
  require Logger
  import Ecto.Query, warn: false

  alias AskDrive.Apps
  alias AskDrive.Batch.{BatchRun, Scheduler}
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.{Repo, Settings}

  @doc "Whether the nightly batch is going through the desks."
  def running?, do: Process.whereis(__MODULE__) != nil

  @doc "Runs the nightly batch for `apps` (in this process, which it registers)."
  def run(apps, opts \\ []) do
    Process.register(self(), __MODULE__)

    cutoff =
      Keyword.get_lazy(opts, :cutoff, fn ->
        Scheduler.calculate_deadline(Settings.platform_setting!())
      end)

    Logger.info(
      "Nightly batch: #{length(apps)} desk(s), generation until #{inspect(cutoff)} (F-355)"
    )

    waiting = import_pass(apps)
    generate_pass(waiting, cutoff)
    :ok
  after
    # a desk still waiting here never got its turn (the night crashed): say so, rather than
    # leave it waiting forever. "failed" still counts as the night's run, so a crash that
    # recurs isn't retried every minute.
    Apps.each(fn _app ->
      Repo.update_all(from(b in BatchRun, where: b.status == "waiting"),
        set: [
          status: "failed",
          finished_at: DateTime.utc_now() |> DateTime.truncate(:second),
          error: "夜間バッチが途中で終了したため、想定QAの生成を行いませんでした"
        ]
      )
    end)

    if Process.whereis(__MODULE__) == self(), do: Process.unregister(__MODULE__)
  end

  # --- Pass 1: import ----------------------------------------------------------------------

  defp import_pass(apps) do
    apps
    |> import_queue()
    |> Enum.flat_map(fn app ->
      Logger.info("Nightly batch: #{app.slug} imports")

      result =
        Apps.with_app(app, fn ->
          Scheduler.run_batch(trigger: "auto", stage: :ingest, night: true)
        end)

      case result do
        {:ok, %BatchRun{status: "waiting", id: id}} -> [{app, id}]
        _ -> []
      end
    end)
  end

  @doc "`apps` in the order they import: the least imported first (ties keep their order)."
  def import_queue(apps) do
    apps
    |> Enum.map(&{&1, Apps.with_app(&1, fn -> import_order() end)})
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Where the current app goes in the import pass: lower first. The share of its documents
  imported, or -1 with none yet (a new desk: everything is still to import).
  """
  def import_order do
    total = Repo.aggregate(Document, :count)
    indexed = Repo.aggregate(from(d in Document, where: d.status == "indexed"), :count)
    if total == 0, do: -1.0, else: indexed / total
  end

  # --- Pass 2: generate --------------------------------------------------------------------

  defp generate_pass(waiting, cutoff), do: waiting |> generate_queue() |> generate_in_turn(cutoff)

  @doc """
  The waiting `{app, run_id}`s in the order they generate, each with its `backlog/0`: the
  least covered first (ties keep their order).
  """
  def generate_queue(waiting) do
    waiting
    |> Enum.map(fn {app, id} -> {app, id, Apps.with_app(app, fn -> backlog() end)} end)
    |> Enum.sort_by(fn {_app, _id, backlog} -> backlog.coverage end)
  end

  defp generate_in_turn([], _cutoff), do: :ok

  defp generate_in_turn([{app, id, backlog} | rest], cutoff) do
    deadline = share_deadline(backlog.pending, Enum.map(rest, &elem(&1, 2).pending), cutoff)

    Logger.info(
      "Nightly batch: #{app.slug} generates #{backlog.pending} chunk(s) until #{inspect(deadline)}"
    )

    Apps.with_app(app, fn -> Scheduler.resume_batch(id, deadline: deadline, night: true) end)
    generate_in_turn(rest, cutoff)
  end

  @doc """
  When a desk with `pending` chunks to generate must stop, with `others` (the later desks'
  pending counts) still to go: its share of the time left until `cutoff`, in proportion to
  its pending chunks; the last desk gets all of it. Never past the cut-off.
  """
  def share_deadline(pending, others, cutoff, now \\ DateTime.utc_now()) do
    left = max(DateTime.diff(cutoff, now), 0)
    all = pending + Enum.sum(others)

    share =
      cond do
        others == [] -> left
        all == 0 -> 0
        true -> div(left * pending, all)
      end

    now |> DateTime.add(share) |> DateTime.truncate(:second)
  end

  @doc """
  The current app's generation backlog: chunks still to generate (as the generate phase
  picks them), and the share of all chunks that need none (lower: generated first).
  """
  def backlog do
    pending =
      Repo.one(
        from c in subquery(Scheduler.pending_generation_query() |> select([c], c.id)),
          select: count()
      )

    total = Repo.aggregate(Chunk, :count)
    coverage = if total == 0, do: 1.0, else: 1 - pending / total
    %{pending: pending, total: total, coverage: coverage}
  end
end
