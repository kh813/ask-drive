defmodule AskDrive.Batch.ItemLogTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Batch.{BatchRun, EmbedChunksWorker, ItemLog}
  alias AskDrive.Documents.Document
  alias AskDrive.Repo

  setup do
    {:ok, run} =
      %BatchRun{}
      |> BatchRun.changeset(%{started_at: DateTime.utc_now(), status: "running"})
      |> Repo.insert()

    %{run: run}
  end

  test "list_for_run/1 puts failures first", %{run: run} do
    ItemLog.record(run.id, %{phase: "sync", name: "a.pdf", status: "created"})

    ItemLog.record(run.id, %{phase: "embed_chunks", name: "a.pdf", status: "failed", message: "x"})

    assert [%{status: "failed"}, %{status: "created"}] = ItemLog.list_for_run(run.id)
  end

  test "record/2 without a batch stores nothing" do
    assert :ok = ItemLog.record(nil, %{phase: "sync", status: "created"})
    assert Repo.aggregate(ItemLog, :count, :id) == 0
  end

  test "describe_reason/1 explains Drive's 404 as a permission problem" do
    assert ItemLog.describe_reason("HTTP 404: %{...}") =~ "閲覧権限"
  end

  test "EmbedChunksWorker records a failed row with the reason when extraction fails", %{
    run: run
  } do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "file_log_test",
        name: "USB利用規程",
        mime_type: "application/vnd.google-apps.document",
        status: "pending"
      })
      |> Repo.insert()

    # No Drive credentials in the test DB, so the export fails before any HTTP call.
    assert {:error, _} =
             EmbedChunksWorker.perform(%Oban.Job{
               args: %{"document_id" => doc.id, "batch_run_id" => run.id}
             })

    assert [log] = ItemLog.list_for_run(run.id)
    assert log.phase == "embed_chunks"
    assert log.status == "failed"
    assert log.name == "USB利用規程"
    assert log.message =~ "本文の取得・抽出に失敗"
    assert is_integer(log.duration_ms)
  end
end
