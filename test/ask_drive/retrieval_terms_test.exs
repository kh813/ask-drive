defmodule AskDrive.RetrievalTermsTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.Retrieval

  test "extract_terms/1 splits a Japanese question into searchable terms" do
    assert Retrieval.extract_terms("ＵＳＢメモリの利用ルールは？") ==
             ["usbメモリ", "usb", "メモリ", "利用ルール", "利用", "ルール"]

    assert Retrieval.extract_terms("クラウドサービスを安全に使うための注意点を教えてください") ==
             ["クラウドサービス", "安全", "注意点"]
  end

  test "keyword_search/2 finds a chunk from a natural question, not only a verbatim phrase" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "terms_doc",
        name: "情報セキュリティ規程",
        mime_type: "application/pdf",
        status: "indexed"
      })
      |> Repo.insert()

    {:ok, hit} =
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        content_hash: "h0",
        content: "USBメモリなどの外部記憶媒体は、会社が貸与したもののみ利用できる。持ち出しのルールは別表のとおり。"
      })
      |> Repo.insert()

    {:ok, _other} =
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: 1,
        content_hash: "h1",
        content: "来客時は受付で入館証を発行し、退館時に回収する。"
      })
      |> Repo.insert()

    assert [{id, _} | _] = Retrieval.keyword_search("USBメモリの利用ルールは？")
    assert id == hit.id
  end

  test "chunks_fts follows inserts and deletes on chunks (triggers)" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{drive_file_id: "fts_doc", name: "d", mime_type: "text/plain"})
      |> Repo.insert()

    {:ok, chunk} =
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        content_hash: "h",
        content: "テレワーク時のVPN接続手順"
      })
      |> Repo.insert()

    match = fn ->
      {:ok, %{rows: rows}} =
        Repo.query("SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ?", [~s("VPN接続")])

      List.flatten(rows)
    end

    assert match.() == [chunk.id]
    Repo.delete!(chunk)
    assert match.() == []
  end
end
