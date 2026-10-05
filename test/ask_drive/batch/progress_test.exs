defmodule AskDrive.Batch.ProgressTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Batch.{BatchRun, Progress}

  defp run!(attrs \\ %{}) do
    %BatchRun{}
    |> BatchRun.changeset(Map.merge(%{started_at: DateTime.utc_now(), status: "running"}, attrs))
    |> Repo.insert!()
  end

  setup do
    on_exit(fn -> Progress.unbind() end)
  end

  test "reports go to the bound run; unbound calls are no-ops" do
    run = run!()
    assert Progress.start_phase("sync", 10) == :ok
    assert Repo.get!(BatchRun, run.id).progress_phase == nil

    Progress.bind(run.id)
    Progress.start_phase("embed_chunks", 208)
    Progress.item(45, "/Manual/a.pdf")
    Progress.detail("埋め込み 64 / 186 チャンク")

    run = Repo.get!(BatchRun, run.id)
    assert run.progress_phase == "embed_chunks"
    assert {run.progress_done, run.progress_total} == {45, 208}
    assert run.progress_item == "/Manual/a.pdf"
    assert run.progress_detail == "埋め込み 64 / 186 チャンク"

    # a new item clears the previous item's detail; extra fields update the run too
    Progress.item(46, "/Manual/b.pdf", %{qa_generated: 7})
    run = Repo.get!(BatchRun, run.id)
    assert run.progress_detail == nil
    assert run.qa_generated == 7
  end

  test "a stop request is honoured at the next report: it throws :batch_stop_requested" do
    run = run!()
    Progress.bind(run.id)
    assert Progress.item(0, "/a.pdf") == :ok

    Repo.update_all(from(b in BatchRun, where: b.id == ^run.id),
      set: [stop_requested_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    assert catch_throw(Progress.item(1, "/b.pdf")) == :batch_stop_requested
    assert catch_throw(Progress.detail("埋め込み 32 / 186 チャンク")) == :batch_stop_requested
    assert catch_throw(Progress.start_phase("verify", 0)) == :batch_stop_requested
  end

  test "overview: step, phase %, weighted overall %, time left from the pace so far" do
    started = ~U[2026-09-29 08:00:00Z]

    run =
      run!(%{
        kind: "full",
        progress_phase: "embed_chunks",
        progress_done: 50,
        progress_total: 200,
        progress_phase_started_at: started
      })

    view = Progress.overview(run, DateTime.add(started, 600))

    assert %{step: 3, steps: 6, percent: 25, done: 50, total: 200} = view
    # sync 10 + invalidate 1 + 35 × 0.25 = 19.75 of 100
    assert view.overall == 19
    # 50 in 600 s → 150 more ≈ 1800 s
    assert view.eta_seconds == 1800
    assert view.label =~ "取り込み"
  end

  test "overview of an ingest-only run weighs its 4 steps; no progress → nil" do
    run = run!(%{kind: "ingest_only", progress_phase: "embed_chunks", progress_total: 4})
    assert %{step: 3, steps: 4, overall: 22, eta_seconds: nil} = Progress.overview(run)
    assert Progress.overview(run!()) == nil
  end

  describe "overall % by expected time (F-354)" do
    # 4/6 into a full batch, but QA generation has barely started: 10 of 200 chunks in 50 min
    defp generating_run do
      run!(%{
        kind: "full",
        started_at: ~U[2026-09-29 08:00:00Z],
        progress_phase: "generate",
        progress_done: 10,
        progress_total: 200,
        progress_phase_started_at: ~U[2026-09-29 08:10:00Z]
      })
    end

    @history %{
      "embed_questions" => %{median: 60, rate: 0.5},
      "verify" => %{median: 10, rate: nil}
    }

    test "step 4 of 6 with most of the time still ahead shows a small percentage" do
      now = ~U[2026-09-29 09:00:00Z]
      view = Progress.overview(generating_run(), now, history: @history)

      # 3000 s for 10 chunks → 57,000 s more, then 60 + 10 s; 3,600 s spent so far
      assert view.basis == :time
      assert view.remaining_seconds == 57_070
      assert view.overall == 5
      assert view.step == 4

      # by the fixed weights it would have been 48%
      assert Progress.overview(generating_run(), now).overall == 48
    end

    test "generation stops at the cut-off, so the time left does too" do
      now = ~U[2026-09-29 09:00:00Z]

      view =
        Progress.overview(generating_run(), now,
          history: @history,
          deadline: DateTime.add(now, 3600)
        )

      assert view.remaining_seconds == 3670
      assert view.overall == 49
    end

    test "a later phase is estimated from earlier runs; the current one before its first item from their time per item" do
      for {phase, secs, items} <- [
            {"generate", 7200, 100},
            {"embed_questions", 120, 300},
            {"verify", 6, 0}
          ] do
        Repo.insert!(%AskDrive.Batch.BatchPhaseStat{
          batch_run_id: run!(%{kind: "full", status: "completed"}).id,
          phase_name: phase,
          duration_seconds: secs,
          items_count: items,
          status: "completed"
        })
      end

      history = Progress.phase_history("full")
      assert history["generate"] == %{median: 7200, rate: 72.0}
      assert history["verify"].rate == nil

      run =
        run!(%{
          kind: "full",
          started_at: ~U[2026-09-29 08:00:00Z],
          progress_phase: "embed_chunks",
          progress_done: 0,
          progress_total: 0,
          progress_phase_started_at: ~U[2026-09-29 08:10:00Z]
        })

      # embed_chunks has no history: falls back to the weights
      assert Progress.overview(run, ~U[2026-09-29 08:20:00Z], history: history).basis == :weights

      history = Map.put(history, "embed_chunks", %{median: 1200, rate: nil})
      view = Progress.overview(run, ~U[2026-09-29 08:20:00Z], history: history)
      # 600 s left of embedding, then 7200 + 120 + 6; 1200 s spent
      assert view.remaining_seconds == 7926
      assert view.overall == 13
    end
  end
end
