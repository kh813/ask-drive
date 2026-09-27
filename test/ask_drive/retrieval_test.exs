defmodule AskDrive.RetrievalTest do
  use AskDrive.DataCase
  alias AskDrive.Documents.{Document, Chunk}
  alias AskDrive.Retrieval
  alias AskDrive.Vector

  test "keyword_search finds chunks by trigram and substring" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "doc_retrieval_1",
        name: "就業規則.pdf",
        mime_type: "application/pdf"
      })
      |> Repo.insert()

    {:ok, chunk1} =
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        heading: "有給休暇",
        content: "年次有給休暇は入社後6ヶ月継続勤務した場合に付与されます。",
        content_hash: "h1"
      })
      |> Repo.insert()

    # Keyword search
    results = Retrieval.keyword_search("有給休暇")
    assert length(results) >= 1
    assert {matched_id, _rank} = List.first(results)
    assert matched_id == chunk1.id
  end

  test "hybrid_search merges vector and keyword results and respects document limits" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "doc_retrieval_2",
        name: "技術仕様書.md",
        mime_type: "text/markdown"
      })
      |> Repo.insert()

    dummy_vec = for i <- 1..1024, do: if(i == 1, do: 1.0, else: 0.0)
    blob = Vector.encode(dummy_vec)
    json_vec = Vector.to_json(dummy_vec)

    for i <- 1..5 do
      {:ok, c} =
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          position: i,
          heading: "セクション#{i}",
          content: "Phoenix LiveView SQLite3 システム内容 #{i}",
          content_hash: "h_#{i}",
          embedding: blob
        })
        |> Repo.insert()

      Repo.query!("INSERT INTO vec_chunks(chunk_id, embedding) VALUES (?, ?)", [c.id, json_vec])
    end

    results = Retrieval.hybrid_search("Phoenix", dummy_vec, limit: 5)
    # Capped at max 3 per doc
    assert length(results) <= 3
    assert Enum.all?(results, fn {chunk, score} -> is_map(chunk) and score > 0 end)
  end
end
