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
    # 600 s for 52 of 208 → about 30 more minutes (a second of test time may round it to 31)
    assert render(view) =~ ~r/残り 約 3[01] 分/
    assert has_element?(view, "#auto-batch-status", "全体の目安 19%")
  end

  test "a running batch can be stopped from the dashboard (F-341)", %{conn: conn} do
    run = run!(~N[2026-09-29 08:38:00], %{status: "running", finished_at: nil})

    {:ok, view, _html} = live(conn, ~p"/it-support/admin")

    # the trigger buttons give way to the stop button while it runs
    refute has_element?(view, "#trigger-batch-btn")
    view |> element("#stop-batch-btn") |> render_click()

    assert AskDrive.Repo.get!(BatchRun, run.id).stop_requested_at
    assert has_element?(view, "#stop-requested", "処理中の項目が終わり次第止まります")
    refute has_element?(view, "#stop-batch-btn")

    # once stopped, it shows as such and the buttons come back
    AskDrive.Repo.get!(BatchRun, run.id)
    |> BatchRun.changeset(%{status: "stopped", finished_at: DateTime.utc_now()})
    |> AskDrive.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/it-support/admin")
    assert has_element?(view, "#batch-run-#{run.id}", "停止（手動）")
    assert has_element?(view, "#trigger-batch-btn")
  end

  test "a failed run shows why it failed", %{conn: conn} do
    run!(~N[2026-09-29 09:40:00], %{
      status: "failed",
      error: "** (MatchError) no match of right hand side value: {:error, #Ecto.Changeset<>}"
    })

    {:ok, view, _html} = live(conn, ~p"/it-support/admin")
    assert has_element?(view, "#batch-error", "失敗の原因")
    assert has_element?(view, "#batch-error", "MatchError")
  end

  test "a failed run offers to resume, with what is left; given-up chunks can be put back", %{
    conn: conn
  } do
    run!(~N[2026-09-29 09:40:00], %{status: "failed", error: "boom"})

    doc =
      %AskDrive.Documents.Document{}
      |> AskDrive.Documents.Document.changeset(%{
        drive_file_id: "d1",
        name: "規則.pdf",
        mime_type: "application/pdf",
        status: "indexed"
      })
      |> AskDrive.Repo.insert!()

    for {i, attempts} <- [{0, 0}, {1, 3}] do
      %AskDrive.Documents.Chunk{}
      |> AskDrive.Documents.Chunk.changeset(%{
        document_id: doc.id,
        position: i,
        content: "c#{i}",
        content_hash: "c#{i}"
      })
      |> Ecto.Changeset.change(
        qa_attempts: attempts,
        qa_error: if(attempts > 0, do: "JSON parse failed after retry")
      )
      |> AskDrive.Repo.insert!()
    end

    {:ok, view, _html} = live(conn, ~p"/it-support/admin")

    assert has_element?(view, "#batch-resume", "QA 未生成 1 チャンク")
    assert has_element?(view, "#batch-resume", "3 回失敗して除外中 1 チャンク")
    assert has_element?(view, "#resume-batch-btn")
    assert has_element?(view, "#given-up-chunks", "規則.pdf（チャンク 2）")
    assert has_element?(view, "#given-up-chunks", "JSON parse failed")

    # the header leads to resuming as well, and shows the running version
    assert has_element?(view, "#resume-header-btn", "続きから再実行（残り 1 チャンク）")
    assert has_element?(view, "#app-version", "v#{AskDrive.version()}")

    view |> element("#retry-given-up-btn") |> render_click()
    refute has_element?(view, "#given-up-chunks")
    assert has_element?(view, "#batch-resume", "QA 未生成 2 チャンク")
  end

  test "a run skipped for a missing API key shows why (F-343)", %{conn: conn} do
    run =
      run!(~N[2026-09-30 00:00:05], %{
        status: "skipped",
        trigger: "auto",
        error: "埋め込み（Google Gemini API）の API キーが未設定のため、実行しませんでした。"
      })

    {:ok, view, _html} = live(conn, ~p"/it-support/admin")
    assert has_element?(view, "#batch-run-#{run.id}", "未実行（API キー未設定）")
    assert has_element?(view, "#batch-note", "API キーが未設定")
    refute has_element?(view, "#batch-error")
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
