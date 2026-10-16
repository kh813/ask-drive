defmodule AskDrive.Batch.NightTest do
  use AskDrive.DataCase, async: false
  import AskDrive.AppsHelper

  alias AskDrive.Apps
  alias AskDrive.Batch.{BatchRun, Night, Scheduler}
  alias AskDrive.Documents.{Chunk, Document}

  setup do
    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        summary_enabled: false,
        extraction_enabled: false
      })

    primary = Enum.find(Apps.list(), & &1.primary)
    %{primary: primary}
  end

  # the primary desk: everything imported, one chunk still without QA
  defp imported_but_not_generated! do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "night_doc",
        name: "規則.docx",
        mime_type: "application/vnd.google-apps.document",
        status: "indexed"
      })
      |> Repo.insert()

    %Chunk{}
    |> Chunk.changeset(%{
      document_id: doc.id,
      position: 0,
      content: "勤務時間は 9 時から 18 時です。",
      content_hash: "night_chunk"
    })
    |> Repo.insert!()
  end

  test "imports the least imported desk first, generates the least covered first (F-355)", %{
    primary: primary
  } do
    imported_but_not_generated!()
    hr = create_app!("hr", "HR")

    assert Apps.with_app(primary, &Night.import_order/0) == 1.0
    assert Apps.with_app(hr, &Night.import_order/0) == -1.0
    assert Enum.map(Night.import_queue([primary, hr]), & &1.slug) == ["hr", primary.slug]

    assert %{pending: 1, total: 1, coverage: +0.0} = Apps.with_app(primary, &Night.backlog/0)
    assert %{pending: 0, total: 0, coverage: 1.0} = Apps.with_app(hr, &Night.backlog/0)

    # the primary desk has generated nothing yet, HR has nothing to generate
    assert [{p, 1, %{pending: 1}}, {%{slug: "hr"}, 2, %{pending: 0}}] =
             Night.generate_queue([{hr, 2}, {primary, 1}])

    assert p.slug == primary.slug
  end

  test "the time left is shared by the chunks each desk has left; the last desk gets the rest" do
    now = ~U[2026-10-06 02:00:00Z]
    cutoff = ~U[2026-10-06 08:00:00Z]

    # 300 of 400 chunks → 3/4 of the 6 hours
    assert Night.share_deadline(300, [100], cutoff, now) == ~U[2026-10-06 06:30:00Z]
    assert Night.share_deadline(100, [], cutoff, now) == cutoff
    # nothing left anywhere: no time for this one, the rest for the others
    assert Night.share_deadline(0, [0], cutoff, now) == now
    # past the cut-off: no generation at all
    assert Night.share_deadline(10, [], cutoff, ~U[2026-10-06 08:30:00Z]) ==
             ~U[2026-10-06 08:30:00Z]
  end

  test "runs every desk in two passes; past the night's cut-off nothing generates (no rollover to the next morning)",
       %{primary: primary} do
    imported_but_not_generated!()
    hr = create_app!("hr", "HR")
    cutoff = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

    assert :ok = Night.run([primary, hr], cutoff: cutoff)
    refute Night.running?()

    for app <- [primary, hr] do
      [run] = Apps.with_app(app, fn -> Repo.all(BatchRun) end)
      assert run.trigger == "auto" and run.kind == "full"
      assert run.status in ["completed", "deadline_reached"]
      assert DateTime.compare(run.generation_deadline, DateTime.add(DateTime.utc_now(), 5)) == :lt
    end

    [run] = Repo.all(BatchRun)
    assert run.status == "deadline_reached"
    assert run.qa_generated == 0
  end

  test "a desk waiting for its turn can be stopped; it then never generates" do
    {:ok, run} = Scheduler.run_batch(trigger: "auto", stage: :ingest, night: true)
    assert run.status == "waiting"
    assert Scheduler.running?() == false

    assert :ok = Scheduler.request_stop()
    assert Repo.get!(BatchRun, run.id).status == "stopped"
    assert {:error, :not_waiting} = Scheduler.resume_batch(run.id)
  end

  test "a waiting run resumes into generation and finishes" do
    {:ok, run} = Scheduler.run_batch(trigger: "auto", stage: :ingest, night: true)
    deadline = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

    assert {:ok, %BatchRun{status: "completed"} = run} =
             Scheduler.resume_batch(run.id, deadline: deadline)

    assert run.generation_deadline == deadline
  end
end
