defmodule AskDrive.Batch.SchedulerTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Batch.{BatchPhaseStat, Scheduler}
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.Repo

  describe "Scheduler 6-phase pipeline" do
    @tag timeout: 180_000
    test "run_batch/1 executes 6 phases and writes batch_runs and batch_phase_stats records" do
      # Prepare sample document and chunk
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          drive_file_id: "doc_test_1",
          name: "規則.docx",
          mime_type: "application/vnd.google-apps.document",
          status: "indexed",
          content_hash: "hash_abc"
        })
        |> Repo.insert()

      {:ok, _chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          position: 0,
          heading: "第1章",
          content: "当社の勤務時間は午前9時から午後6時までです。",
          content_hash: "chunk_hash_abc",
          token_estimate: 24
        })
        |> Repo.insert()

      # Disable summary and extraction during this integration test to focus on pipeline orchestration
      setting = AskDrive.Settings.get_setting!()

      AskDrive.Settings.update_setting(setting, %{
        summary_enabled: false,
        extraction_enabled: false
      })

      # Run batch synchronously
      {:ok, batch_run} = Scheduler.run_batch()

      assert batch_run.id != nil
      assert batch_run.status in ["completed", "deadline_reached"]
      assert batch_run.started_at != nil
      assert batch_run.finished_at != nil

      stats = Repo.all(from s in BatchPhaseStat, where: s.batch_run_id == ^batch_run.id)
      assert length(stats) == 6

      phase_names = Enum.map(stats, & &1.phase_name)
      assert "sync" in phase_names
      assert "invalidate" in phase_names
      assert "embed_chunks" in phase_names
      assert "generate" in phase_names
      assert "embed_questions" in phase_names
      assert "verify" in phase_names
    end

    @tag timeout: 120_000
    test "run_batch(ingest_only: true) skips generation and never enters night_batch" do
      AskDrive.Runtime.Mode.set_mode(:daytime)

      {:ok, batch_run} = Scheduler.run_batch(ingest_only: true)

      assert batch_run.kind == "ingest_only"
      assert batch_run.status == "completed"

      phase_names =
        Repo.all(from s in BatchPhaseStat, where: s.batch_run_id == ^batch_run.id)
        |> Enum.map(& &1.phase_name)

      assert "sync" in phase_names
      assert "embed_chunks" in phase_names
      assert "verify" in phase_names
      refute "generate" in phase_names
      refute "embed_questions" in phase_names

      refute AskDrive.Runtime.Mode.current_mode() == :night_batch
    end

    test "ran_since?/1 ignores batches aborted by a restart" do
      since = DateTime.add(DateTime.utc_now(), -60)

      {:ok, run} =
        %AskDrive.Batch.BatchRun{}
        |> AskDrive.Batch.BatchRun.changeset(%{started_at: DateTime.utc_now(), status: "aborted"})
        |> Repo.insert()

      refute Scheduler.ran_since?(since)

      run |> AskDrive.Batch.BatchRun.changeset(%{status: "completed"}) |> Repo.update!()
      assert Scheduler.ran_since?(since)
    end

    test "running?/0 reflects a batch in progress" do
      refute Scheduler.running?()

      {:ok, _} =
        %AskDrive.Batch.BatchRun{}
        |> AskDrive.Batch.BatchRun.changeset(%{started_at: DateTime.utc_now(), status: "running"})
        |> Repo.insert()

      assert Scheduler.running?()
      assert {:error, :already_running} = Scheduler.run_batch(ingest_only: true)
    end
  end
end
