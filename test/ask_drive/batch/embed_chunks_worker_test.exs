defmodule AskDrive.Batch.EmbedChunksWorkerTest do
  use AskDrive.DataCase
  alias AskDrive.Documents.{Document, Chunk}
  alias AskDrive.Batch.EmbedChunksWorker
  alias AskDrive.Settings

  test "process_chunks_and_embed chunks text and inserts into chunks and vec_chunks" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "embed_test_file_001",
        name: "test.txt",
        mime_type: "text/plain"
      })
      |> Repo.insert()

    setting = Settings.get_setting!()
    text = "これは第一段落です。これは第二段落です。"

    # Process and embed
    assert {:ok, _} = EmbedChunksWorker.process_chunks_and_embed(doc, text, "hash_xyz", setting)

    # Check chunks table
    chunks = Repo.all(from c in Chunk, where: c.document_id == ^doc.id, order_by: c.position)
    assert length(chunks) >= 1

    first_chunk = List.first(chunks)
    assert first_chunk.content =~ "これは第一段落です"
    assert is_binary(first_chunk.embedding)

    # Check vec_chunks virtual table
    {:ok, %{rows: [[count]]}} =
      Repo.query("SELECT COUNT(*) FROM vec_chunks WHERE chunk_id = ?", [first_chunk.id])

    assert count == 1
  end
end
