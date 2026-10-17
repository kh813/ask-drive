defmodule AskDrive.Batch.EmbedTimeoutSplitTest do
  @moduledoc """
  Embedding a long document on a slow (CPU) Ollama: a batch that times out is split in half
  and embedded part by part, instead of being sent again whole until the document fails
  (three long PDFs failed after ~95s each on a server without a GPU, v0.2.0).
  """
  use AskDrive.DataCase, async: false

  alias AskDrive.Batch.EmbedChunksWorker
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.{Settings, StubOllama}

  setup do
    {server, url} = StubOllama.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    # a timeout of 300ms whatever the size, and 30ms per chunk: 16 chunks (480ms) time out,
    # 8 (240ms) don't
    Application.put_env(:ask_drive, :embed_timeout_base_ms, 300)
    Application.put_env(:ask_drive, :embed_timeout_per_chunk_ms, 0)
    StubOllama.put_embed_delay_per_input(30)

    on_exit(fn ->
      Application.delete_env(:ask_drive, :embed_timeout_base_ms)
      Application.delete_env(:ask_drive, :embed_timeout_per_chunk_ms)
    end)

    {:ok, setting} =
      Settings.update_setting(Settings.get_setting!(), %{
        ollama_host: url,
        embed_provider: "ollama",
        embed_model: "bge-m3"
      })

    %{setting: setting}
  end

  test "a batch that times out is embedded in halves, and the document succeeds", %{
    setting: setting
  } do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "long-#{System.unique_integer([:positive])}",
        name: "manual.pdf",
        mime_type: "application/pdf"
      })
      |> Repo.insert()

    text =
      1..80
      |> Enum.map(fn i ->
        "第#{i}条 " <> String.duplicate("情報セキュリティ対策の手順と例外の扱いを定める。", 12)
      end)
      |> Enum.join("\n\n")

    assert {:ok, _} = EmbedChunksWorker.process_chunks_and_embed(doc, text, "h-long", setting)

    chunks = Repo.all(from c in Chunk, where: c.document_id == ^doc.id)
    assert length(chunks) > 16

    # every full batch (16) timed out once and went as two halves (8 + 8), never whole again
    sizes = received_sizes()
    full = Enum.count(sizes, &(&1 == 16))
    assert full == div(length(chunks), 16)
    assert Enum.count(sizes, &(&1 == 8)) >= 2 * full
    refute Enum.any?(sizes, &(&1 > 16))

    {:ok, %{rows: [[count]]}} =
      Repo.query(
        "SELECT COUNT(*) FROM vec_chunks WHERE chunk_id IN (SELECT id FROM chunks WHERE document_id = ?)",
        [doc.id]
      )

    assert count == length(chunks)
  end

  test "the timeout grows with the batch" do
    Application.delete_env(:ask_drive, :embed_timeout_base_ms)
    Application.delete_env(:ask_drive, :embed_timeout_per_chunk_ms)

    assert EmbedChunksWorker.embed_timeout(1) == 38_000
    assert EmbedChunksWorker.embed_timeout(16) == 158_000
  end

  defp received_sizes(acc \\ []) do
    receive do
      {:stub_embed, n} -> received_sizes([n | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
