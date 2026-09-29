defmodule AskDriveWeb.AdminBatchHistoryTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Batch.{BatchRun, ItemLog, Scheduler}
  alias AskDrive.Clock

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
  end

  defp run!(local_start, attrs) do
    start = Clock.local_to_utc(local_start)

    %BatchRun{}
    |> BatchRun.changeset(
      Map.merge(
        %{started_at: start, finished_at: DateTime.add(start, 125), status: "completed"},
        attrs
      )
    )
    |> AskDrive.Repo.insert!()
  end

  test "history lists manual and automatic runs; clicking a row shows its details", %{
    conn: conn
  } do
    manual = run!(~N[2026-09-28 22:11:22], %{status: "aborted", trigger: "manual"})
    auto = run!(~N[2026-09-28 23:00:05], %{trigger: "auto", qa_generated: 12})

    ItemLog.record(manual.id, %{
      phase: "embed_chunks",
      name: "/Manual/a.pdf",
      status: "indexed",
      chunks: 186
    })

    {:ok, view, html} = live(conn, ~p"/it-support/admin")

    assert html =~ "夜間バッチの自動実行と履歴"
    assert has_element?(view, "#batch-run-#{manual.id}", "中断（再起動）")
    assert has_element?(view, "#batch-run-#{manual.id}", "手動")
    assert has_element?(view, "#batch-run-#{auto.id}", "自動")
    assert has_element?(view, "#batch-run-#{auto.id}", "2分5秒")
    assert has_element?(view, "#batch-run-#{manual.id}", "—（中断）")

    # newest run is shown by default; clicking the manual one switches the details
    html = view |> element("#batch-run-#{manual.id}") |> render_click()
    assert html =~ "#{manual.id}"
    assert html =~ "/Manual/a.pdf"
  end

  test "a running batch shows its progress: overall %, step, item and time left", %{conn: conn} do
    run =
      run!(~N[2026-09-29 08:38:00], %{
        status: "running",
        finished_at: nil,
        progress_phase: "embed_chunks",
        progress_done: 52,
        progress_total: 208,
        progress_item: "/Manual/a.pdf",
        progress_detail: "埋め込み 64 / 186 チャンク",
        progress_phase_started_at: DateTime.add(DateTime.utc_now(), -600, :second)
      })

    {:ok, view, _html} = live(conn, ~p"/it-support/admin")

    # 10 + 1 + 35 × 0.25 = 19.75
    assert has_element?(view, "#batch-run-#{run.id}", "19%")
    assert has_element?(view, "#batch-progress", "19%")
    assert has_element?(view, "#batch-progress", "ステップ 3/6")
    assert has_element?(view, "#batch-progress", "52 / 208 件（25%）")
    assert has_element?(view, "#batch-progress", "/Manual/a.pdf")
    assert has_element?(view, "#batch-progress", "埋め込み 64 / 186 チャンク")
    assert has_element?(view, "#batch-progress", "残り 約 30 分")
    assert has_element?(view, "#auto-batch-status", "全体の目安 19%")
  end

  test "auto_status: missed, done (automatic only), due, next start" do
    assert %{state: :missed} = Scheduler.auto_status(~N[2026-09-29 09:00:00])

    # a manual run doesn't stand in for the automatic one
    run!(~N[2026-09-29 00:10:00], %{trigger: "manual"})
    assert %{state: :missed} = Scheduler.auto_status(~N[2026-09-29 09:00:00])

    run!(~N[2026-09-29 00:00:05], %{trigger: "auto"})

    assert %{state: :done, run: %{trigger: "auto"}} =
             Scheduler.auto_status(~N[2026-09-29 09:00:00])

    assert %{state: :due, in_window?: true} = Scheduler.auto_status(~N[2026-09-30 00:30:00])
    assert %{next_start: ~N[2026-09-30 00:00:00]} = Scheduler.auto_status(~N[2026-09-29 09:00:00])
  end

  test "an aborted run shows no duration (its end time is when the next boot noticed)", %{
    conn: conn
  } do
    run = run!(~N[2026-09-28 13:29:00], %{status: "aborted"})
    {:ok, view, _html} = live(conn, ~p"/it-support/admin")
    assert has_element?(view, "#batch-run-#{run.id}", "—（中断）")
  end

  test "a batch that crashes before it starts is recorded as a failed run" do
    # an invalid option value makes the insert raise inside do_run_batch
    assert {:error, _} = Scheduler.run_batch(trigger: "bogus")
    assert [%{status: "failed"}] = Scheduler.list_runs(5) |> Enum.filter(&(&1.status == "failed"))
  end
end
