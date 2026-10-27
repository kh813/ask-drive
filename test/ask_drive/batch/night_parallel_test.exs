defmodule AskDrive.Batch.NightParallelTest do
  @moduledoc """
  The nightly batch generates for the desks on cloud APIs at once; the desks using the same
  API key share its slots (F-841).
  """
  use AskDrive.DataCase, async: false
  import AskDrive.AppsHelper

  alias AskDrive.{Apps, LLM, Settings, StubGemini, StubOllama}
  alias AskDrive.Batch.{BatchRun, Night, Scheduler}
  alias AskDrive.Documents.{Chunk, Document}

  setup do
    {ollama, ollama_url} = StubOllama.start!(self())
    {gemini, gemini_url} = StubGemini.start!(self())

    on_exit(fn ->
      AskDrive.Runtime.Mode.set_mode(:daytime)
      Process.exit(ollama, :normal)
      Process.exit(gemini, :normal)
    end)

    StubGemini.set(:parts, [%{"text" => ~s([{"question": "勤務時間は？", "answer": "9時から18時。"}])}])
    StubGemini.set(:delay, 150)

    primary = Enum.find(Apps.list(), & &1.primary)
    hr = create_app!("hr", "HR")
    %{primary: primary, hr: hr, ollama_url: ollama_url, gemini_url: gemini_url}
  end

  # a desk generating on Gemini with `key`, `concurrency` at once, 4 chunks without QA
  defp cloud_desk!(app, key, concurrency, ctx) do
    desk!(app, ctx, %{
      batch_llm_mode: "cloud",
      cloud_llm_provider: "gemini",
      cloud_llm_model: "gemini-2.5-flash",
      gemini_base_url: ctx.gemini_url,
      gemini_api_key: key,
      cloud_generation_concurrency: concurrency
    })
  end

  # a desk generating on the local LLM (Ollama), 4 chunks without QA
  defp local_desk!(app, ctx), do: desk!(app, ctx, %{batch_llm_mode: "local"})

  defp desk!(app, ctx, attrs) do
    Apps.with_app(app, fn ->
      {:ok, _} =
        Settings.update_setting(
          Settings.get_setting!(),
          Map.merge(
            %{
              ollama_host: ctx.ollama_url,
              embed_provider: "ollama",
              llm_provider: "ollama",
              summary_enabled: false,
              extraction_enabled: false
            },
            attrs
          )
        )

      doc =
        %Document{}
        |> Document.changeset(%{
          drive_file_id: "doc_#{app.slug}",
          name: "規則.pdf",
          mime_type: "application/pdf",
          status: "indexed",
          content_hash: "h"
        })
        |> Repo.insert!()

      for i <- 0..3 do
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          position: i,
          content: "#{app.slug} 第#{i}条 勤務時間は午前9時から午後6時までです。",
          content_hash: "#{app.slug}#{i}"
        })
        |> Repo.insert!()
      end
    end)
  end

  defp night!(apps) do
    cutoff = DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)
    assert :ok = Night.run(apps, cutoff: cutoff)

    for app <- apps do
      [run] = Apps.with_app(app, fn -> Repo.all(BatchRun) end)
      assert run.status == "completed"
      assert run.qa_generated > 0
      # each until the night's cut-off, not a share of it
      assert run.generation_deadline == cutoff
    end
  end

  test "desks with their own API keys generate at the same time", ctx do
    cloud_desk!(ctx.primary, "key-sales", 4, ctx)
    cloud_desk!(ctx.hr, "key-hr", 4, ctx)
    refute Apps.with_app(ctx.primary, &LLM.quota_key/0) == Apps.with_app(ctx.hr, &LLM.quota_key/0)

    night!([ctx.primary, ctx.hr])
    assert StubGemini.max_in_flight() == 8
  end

  test "desks sharing an API key share its slots", ctx do
    cloud_desk!(ctx.primary, "key-dept", 4, ctx)
    cloud_desk!(ctx.hr, "key-dept", 4, ctx)
    assert Apps.with_app(ctx.primary, &LLM.quota_key/0) == Apps.with_app(ctx.hr, &LLM.quota_key/0)

    night!([ctx.primary, ctx.hr])
    assert StubGemini.max_in_flight() == 4
  end

  defp run_of(app), do: Apps.with_app(app, fn -> Repo.one!(BatchRun) end)

  # the night in a task, for a test that acts while it generates
  defp start_night!(apps) do
    cutoff = DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)
    Task.async(fn -> Night.run(apps, cutoff: cutoff) end)
  end

  # until `app`'s run is `status` (the night runs in another process; it may not have one yet)
  defp await_status(app, status, tries \\ 200) do
    now = Apps.with_app(app, fn -> Repo.one(BatchRun) end)

    cond do
      now && now.status == status ->
        :ok

      tries == 0 ->
        flunk("#{app.slug}'s run never became #{status} (#{inspect(now && now.status)})")

      true ->
        Process.sleep(25)
        await_status(app, status, tries - 1)
    end
  end

  # until Gemini is asked to generate for `app`'s chunks
  defp await_gemini_for(app) do
    assert_receive {:stub_gemini, call, body}, 5_000

    unless call =~ "generateContent" and inspect(body) =~ "#{app.slug} 第",
      do: await_gemini_for(app)
  end

  test "a desk on the local LLM generates while the cloud desks do, not after them", ctx do
    local_desk!(ctx.primary, ctx)
    cloud_desk!(ctx.hr, "key-hr", 4, ctx)
    StubOllama.put_generate_pieces([~s([{"question": "勤務時間は？", "answer": "9時から18時。"}])])
    # the local model: one chunk at a time, slowly
    StubOllama.put_generate_delay(400)

    night = start_night!([ctx.primary, ctx.hr])

    # the cloud desk is done while the local one is still generating its 4 chunks
    await_status(ctx.hr, "completed")
    assert run_of(ctx.primary).status == "running"

    assert :ok = Task.await(night, 20_000)
    assert %{status: "completed"} = local = run_of(ctx.primary)
    assert local.qa_generated > 0
    assert run_of(ctx.hr).qa_generated > 0
    # the local desk alone on the local model: all the night (to the second), not a share
    # with the cloud desk
    assert DateTime.diff(run_of(ctx.hr).generation_deadline, local.generation_deadline) in 0..1
  end

  test "stopping one desk while they generate at once leaves the others going", ctx do
    cloud_desk!(ctx.primary, "key-sales", 1, ctx)
    cloud_desk!(ctx.hr, "key-hr", 1, ctx)
    StubGemini.set(:delay, 200)

    night = start_night!([ctx.primary, ctx.hr])
    await_gemini_for(ctx.hr)
    assert :ok = Apps.with_app(ctx.hr, &Scheduler.request_stop/0)
    assert :ok = Task.await(night, 20_000)

    assert %{status: "stopped"} = stopped = run_of(ctx.hr)
    assert stopped.qa_generated < 4
    assert %{status: "completed", qa_generated: 4} = run_of(ctx.primary)
    refute Night.running?()
  end

  test "an update pauses every desk generating at once (F-1503)", ctx do
    cloud_desk!(ctx.primary, "key-sales", 1, ctx)
    cloud_desk!(ctx.hr, "key-hr", 1, ctx)
    StubGemini.set(:delay, 200)

    night = start_night!([ctx.primary, ctx.hr])
    await_status(ctx.primary, "running")
    await_status(ctx.hr, "running")

    # what the update does before it restarts
    Apps.each(fn _app -> Scheduler.pause_for_update() end)
    assert :ok = Task.await(night, 20_000)

    for app <- [ctx.primary, ctx.hr] do
      assert %{status: "paused", stop_reason: "update"} = run = run_of(app)
      assert run.qa_generated < 4
    end
  end
end
