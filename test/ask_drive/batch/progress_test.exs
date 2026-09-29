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
end
