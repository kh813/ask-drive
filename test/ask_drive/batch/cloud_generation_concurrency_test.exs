defmodule AskDrive.Batch.CloudGenerationConcurrencyTest do
  @moduledoc """
  QA generation on a cloud API runs several chunks at once (spec F-840); on a local LLM it
  stays one at a time.
  """
  use AskDrive.DataCase, async: false

  alias AskDrive.Batch.Scheduler
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.{Settings, StubGemini, StubOllama}

  setup do
    {ollama, ollama_url} = StubOllama.start!(self())
    {gemini, gemini_url} = StubGemini.start!(self())

    on_exit(fn ->
      AskDrive.Runtime.Mode.set_mode(:daytime)
      Process.exit(ollama, :normal)
      Process.exit(gemini, :normal)
    end)

    {:ok, setting} =
      Settings.update_setting(Settings.get_setting!(), %{
        ollama_host: ollama_url,
        embed_provider: "ollama",
        llm_provider: "ollama",
        batch_llm_mode: "cloud",
        cloud_llm_provider: "gemini",
        cloud_llm_model: "gemini-2.5-flash",
        gemini_base_url: gemini_url,
        gemini_api_key: "k",
        summary_enabled: false,
        extraction_enabled: false
      })

    doc =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "doc_cloud_qa",
        name: "規則.pdf",
        mime_type: "application/pdf",
        status: "indexed",
        content_hash: "h"
      })
      |> Repo.insert!()

    chunks =
      for i <- 0..7 do
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          position: i,
          content: "第#{i}条 勤務時間は午前9時から午後6時までです。",
          content_hash: "c#{i}"
        })
        |> Repo.insert!()
      end

    StubGemini.set(:parts, [%{"text" => ~s([{"question": "勤務時間は？", "answer": "9時から18時。"}])}])
    %{setting: setting, chunks: chunks}
  end

  test "on a cloud API, chunks are generated four at a time", %{chunks: chunks} do
    assert Scheduler.generation_concurrency(Settings.get_setting!()) == 4
    StubGemini.set(:delay, 300)

    started = System.monotonic_time(:millisecond)
    {:ok, run} = Scheduler.run_batch()
    elapsed = System.monotonic_time(:millisecond) - started

    assert run.chunks_processed == 8

    for chunk <- chunks,
        do: assert(Repo.exists?(from q in AskDrive.QA.QAPair, where: q.chunk_id == ^chunk.id))

    # 8 requests of 300ms each: ~2.4s one by one, ~0.6s four at a time
    assert elapsed < 1_800
  end

  test "on a local LLM, one at a time" do
    {:ok, local} = Settings.update_setting(Settings.get_setting!(), %{batch_llm_mode: "local"})
    assert Scheduler.generation_concurrency(local) == 1
  end
end
