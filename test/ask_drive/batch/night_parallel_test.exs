defmodule AskDrive.Batch.NightParallelTest do
  @moduledoc """
  The nightly batch generates for the desks on cloud APIs at once; the desks using the same
  API key share its slots (F-841).
  """
  use AskDrive.DataCase, async: false
  import AskDrive.AppsHelper

  alias AskDrive.{Apps, LLM, Settings, StubGemini, StubOllama}
  alias AskDrive.Batch.{BatchRun, Night}
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
    Apps.with_app(app, fn ->
      {:ok, _} =
        Settings.update_setting(Settings.get_setting!(), %{
          ollama_host: ctx.ollama_url,
          embed_provider: "ollama",
          llm_provider: "ollama",
          batch_llm_mode: "cloud",
          cloud_llm_provider: "gemini",
          cloud_llm_model: "gemini-2.5-flash",
          gemini_base_url: ctx.gemini_url,
          gemini_api_key: key,
          cloud_generation_concurrency: concurrency,
          summary_enabled: false,
          extraction_enabled: false
        })

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
          content: "第#{i}条 勤務時間は午前9時から午後6時までです。",
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
end
