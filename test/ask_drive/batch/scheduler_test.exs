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

    test "the run records its progress; it ends on the last step" do
      AskDrive.Runtime.Mode.set_mode(:daytime)
      {:ok, batch_run} = Scheduler.run_batch(ingest_only: true)

      run = Repo.get!(AskDrive.Batch.BatchRun, batch_run.id)
      assert run.progress_phase == "verify"
      assert run.progress_phase_started_at

      assert %{step: 4, steps: 4, overall: 100} = AskDrive.Batch.Progress.overview(run)
      # the reporting process is released when the run ends
      assert AskDrive.Batch.Progress.current_run_id() == nil
    end

    test "ran_since?/1 ignores batches aborted by a restart" do
      since = DateTime.add(DateTime.utc_now(), -60)

      {:ok, run} =
        %AskDrive.Batch.BatchRun{}
        |> AskDrive.Batch.BatchRun.changeset(%{
          started_at: DateTime.utc_now(),
          status: "aborted",
          trigger: "auto"
        })
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

  describe "stopping a running batch (F-341)" do
    setup do
      {server, url} = AskDrive.StubOllama.start!(self())
      on_exit(fn -> Process.exit(server, :normal) end)

      {:ok, _} =
        AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
          ollama_host: url,
          llm_provider: "ollama",
          embed_provider: "ollama",
          summary_enabled: false,
          extraction_enabled: false
        })

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          drive_file_id: "doc_stop",
          name: "規則.pdf",
          mime_type: "application/pdf",
          status: "indexed",
          content_hash: "h"
        })
        |> Repo.insert()

      for i <- 0..4 do
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          position: i,
          content: "第#{i}条 勤務時間は午前9時から午後6時までです。",
          content_hash: "c#{i}"
        })
        |> Repo.insert!()
      end

      AskDrive.StubOllama.put_generate_pieces([
        ~s([{"question": "勤務時間は？", "answer": "9時から18時です。"}])
      ])

      AskDrive.StubOllama.put_generate_delay(300)

      on_exit(fn ->
        AskDrive.StubOllama.put_generate_delay(0)
        AskDrive.StubOllama.put_generate_pieces(["要約です。"])
        AskDrive.Runtime.Mode.set_mode(:daytime)
      end)

      :ok
    end

    @tag timeout: 60_000
    test "request_stop/0 stops the run at the next chunk; it is recorded as stopped" do
      assert Scheduler.request_stop() == {:error, :not_running}

      owner = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
          Scheduler.run_batch()
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, task.pid)

      # wait until it is generating, then ask it to stop
      wait_until(fn ->
        Repo.exists?(
          from b in AskDrive.Batch.BatchRun,
            where: b.progress_phase == "generate" and b.progress_done >= 1
        )
      end)

      assert Scheduler.request_stop() == :ok
      assert {:ok, run} = Task.await(task, 30_000)

      assert run.status == "stopped"
      assert run.finished_at
      assert run.progress_phase == "generate"
      assert run.progress_done < 5
      # the chunks generated before the stop keep their QA
      assert Repo.aggregate(AskDrive.QA.QAPair, :count) >= 1
      refute Scheduler.running?()
      refute AskDrive.Runtime.Mode.current_mode() == :night_batch
    end
  end

  describe "resuming: only what is left, failed chunks last, given up after 3 (F-342)" do
    setup do
      {server, url} = AskDrive.StubOllama.start!(self())

      on_exit(fn ->
        AskDrive.StubOllama.put_generate_pieces(["要約です。"])
        AskDrive.Runtime.Mode.set_mode(:daytime)
        Process.exit(server, :normal)
      end)

      {:ok, _} =
        AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
          ollama_host: url,
          llm_provider: "ollama",
          embed_provider: "ollama",
          summary_enabled: false,
          extraction_enabled: false
        })

      doc =
        %Document{}
        |> Document.changeset(%{
          drive_file_id: "doc_resume",
          name: "規則.pdf",
          mime_type: "application/pdf",
          status: "indexed",
          content_hash: "h"
        })
        |> Repo.insert!()

      chunk = fn i ->
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          position: i,
          content: "第#{i}条 勤務時間は午前9時から午後6時までです。",
          content_hash: "r#{i}"
        })
        |> Repo.insert!()
      end

      %{doc: doc, done: chunk.(0), todo: chunk.(1)}
    end

    test "a re-run generates only chunks without QA", %{doc: doc, done: done, todo: todo} do
      AskDrive.QA.create_qa_pair(%{
        document_id: doc.id,
        chunk_id: done.id,
        question: "既存",
        answer: "既存",
        status: "active",
        generated_by: "m",
        source_hash: "r0"
      })

      assert %{chunks: 1} = Scheduler.remaining()

      AskDrive.StubOllama.put_generate_pieces([
        ~s([{"question": "勤務時間は？", "answer": "9時から18時。"}])
      ])

      {:ok, run} = Scheduler.run_batch()

      assert run.chunks_processed == 1
      # generation requests only (model unloads also hit /api/generate, without a prompt)
      prompts = for {:stub_generate, %{"prompt" => p}} <- flush_messages(), p != "", do: p
      assert [prompt] = prompts
      assert prompt =~ "第1条"
      assert Repo.exists?(from q in AskDrive.QA.QAPair, where: q.chunk_id == ^todo.id)
      assert %{chunks: 0} = Scheduler.remaining()
    end

    test "unusable output counts against the chunk; after 3 it is skipped until put back",
         %{todo: todo, done: done} do
      AskDrive.StubOllama.put_generate_pieces(["JSON ではない出力"])

      for n <- 1..3 do
        {:ok, _} = Scheduler.run_batch()
        assert Repo.get!(Chunk, todo.id).qa_attempts == n
      end

      chunk = Repo.get!(Chunk, todo.id)
      assert chunk.qa_error =~ "JSON parse failed"
      assert chunk.qa_attempted_at
      assert %{chunks: 0, given_up: 2} = Scheduler.remaining()

      assert Scheduler.given_up_chunks() |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([done.id, todo.id])

      # skipped now: a 4th run doesn't try them
      {:ok, run} = Scheduler.run_batch()
      assert run.chunks_processed == 0

      # put back, and a success clears the record
      assert Scheduler.retry_given_up_chunks() == 2
      AskDrive.StubOllama.put_generate_pieces([~s([{"question": "Q", "answer": "A"}])])
      {:ok, _} = Scheduler.run_batch()
      assert %{qa_attempts: 0, qa_error: nil} = Repo.get!(Chunk, todo.id)
      assert %{chunks: 0, given_up: 0} = Scheduler.remaining()
    end

    test "a failure that says nothing about the chunk (model unreachable) doesn't count",
         %{todo: todo} do
      {:ok, _} =
        AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
          ollama_host: "http://127.0.0.1:1"
        })

      {:ok, _} = Scheduler.run_batch()
      assert Repo.get!(Chunk, todo.id).qa_attempts == 0
    end
  end

  defp flush_messages(acc \\ []) do
    receive do
      msg -> flush_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(25) && wait_until(fun, tries - 1)
    end
  end
end
