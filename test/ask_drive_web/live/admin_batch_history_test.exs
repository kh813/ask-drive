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

    {:ok, view, html} = live(conn, ~p"/admin")

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
    {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, "#batch-run-#{run.id}", "—（中断）")
  end

  test "a batch that crashes before it starts is recorded as a failed run" do
    # an invalid option value makes the insert raise inside do_run_batch
    assert {:error, _} = Scheduler.run_batch(trigger: "bogus")
    assert [%{status: "failed"}] = Scheduler.list_runs(5) |> Enum.filter(&(&1.status == "failed"))
  end
end
