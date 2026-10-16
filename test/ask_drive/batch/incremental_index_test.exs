defmodule AskDrive.Batch.IncrementalIndexTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Batch.EmbedChunksWorker
  alias AskDrive.Documents
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.QA.QAPair
  alias AskDrive.{Repo, Settings, StubOllama}

  setup do
    {server, url} = StubOllama.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    {:ok, setting} =
      Settings.update_setting(Settings.get_setting!(), %{
        ollama_host: url,
        embed_provider: "ollama"
      })

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{drive_file_id: "inc_doc", name: "規程.txt", mime_type: "text/plain"})
      |> Repo.insert()

    %{setting: setting, doc: doc}
  end

  defp sections(texts), do: Enum.map_join(texts, "\n\n", fn {h, body} -> "## #{h}\n#{body}" end)

  defp flush_embeds(acc \\ 0) do
    receive do
      {:stub_embed, n} -> flush_embeds(acc + n)
    after
      50 -> acc
    end
  end

  defp index(doc, text, setting) do
    hash = AskDrive.Ingest.Extractor.content_hash(text)
    EmbedChunksWorker.process_chunks_and_embed(Repo.reload!(doc), text, hash, setting)
  end

  test "editing one section embeds only its chunk and keeps QA of the others", %{
    setting: setting,
    doc: doc
  } do
    body = fn s -> String.duplicate("#{s}に関する規定の本文です。", 8) end

    v1 =
      sections([{"第1章 目的", body.("目的")}, {"第2章 USB", body.("USBメモリ")}, {"第3章 罰則", body.("罰則")}])

    assert {:ok, {:indexed, %{new: new1, reused: 0, removed: 0, total: total}}} =
             index(doc, v1, setting)

    assert new1 == total
    assert flush_embeds() == total

    chunks = Repo.all(from c in Chunk, where: c.document_id == ^doc.id, order_by: c.position)
    kept = hd(chunks)

    {:ok, qa} =
      %QAPair{}
      |> QAPair.changeset(%{
        document_id: doc.id,
        chunk_id: kept.id,
        question: "目的は？",
        answer: "…",
        source_hash: kept.content_hash,
        generated_by: "test",
        status: "active"
      })
      |> Repo.insert()

    v2 =
      sections([{"第1章 目的", body.("目的")}, {"第2章 USB", body.("外部記憶媒体")}, {"第3章 罰則", body.("罰則")}])

    assert {:ok, {:indexed, stats}} = index(doc, v2, setting)
    assert stats.reused >= 2
    assert stats.new >= 1
    assert stats.removed == stats.new
    assert flush_embeds() == stats.new

    # The unchanged chunk is the same row, and its QA is still active
    assert Repo.get(Chunk, kept.id)
    assert Repo.reload!(qa).status == "active"
    assert Repo.reload!(doc).status == "indexed"
  end

  test "unchanged text is skipped even after sync reset the status to pending", %{
    setting: setting,
    doc: doc
  } do
    text = sections([{"第1章", String.duplicate("本文です。", 20)}])
    {:ok, {:indexed, _}} = index(doc, text, setting)
    flush_embeds()

    {:ok, _} = doc |> Repo.reload!() |> Document.changeset(%{status: "pending"}) |> Repo.update()

    # Same text again after sync reset the status: skipped before any chunking/embedding
    reloaded = Repo.reload!(doc)

    assert {:ok, :unchanged} =
             EmbedChunksWorker.index_text(reloaded, text, reloaded.content_hash, setting)

    assert flush_embeds() == 0
    assert Repo.reload!(doc).status == "indexed"
  end

  test "sync keeps an indexed file unchanged when only modifiedTime moved but md5 matches" do
    file = %{
      "id" => "md5_doc",
      "name" => "a.pdf",
      "mimeType" => "application/pdf",
      "modifiedTime" => "2026-09-01T00:00:00Z",
      "md5Checksum" => "abc"
    }

    {:created, doc} = Documents.upsert_document_from_drive(file)
    {:ok, _} = Documents.mark_indexed(doc, "h")

    assert {:unchanged, _} =
             Documents.upsert_document_from_drive(%{
               file
               | "modifiedTime" => "2026-09-02T00:00:00Z"
             })

    assert {:updated, _} =
             Documents.upsert_document_from_drive(%{
               file
               | "modifiedTime" => "2026-09-03T00:00:00Z",
                 "md5Checksum" => "def"
             })
  end

  test "an indexed file from an older pipeline version is re-indexed once (F-337)" do
    file = %{
      "id" => "ver_doc",
      "name" => "b.pdf",
      "mimeType" => "application/pdf",
      "modifiedTime" => "2026-09-01T00:00:00Z",
      "md5Checksum" => "abc"
    }

    {:created, doc} = Documents.upsert_document_from_drive(file)
    {:ok, doc} = Documents.mark_indexed(doc, "h")
    assert doc.index_version == Documents.current_index_version()
    assert {:unchanged, _} = Documents.upsert_document_from_drive(file)

    {:ok, _} = doc |> Document.changeset(%{index_version: 1}) |> Repo.update()
    assert {:updated, updated} = Documents.upsert_document_from_drive(file)
    assert updated.status == "pending"
  end
end
