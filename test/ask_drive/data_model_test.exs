defmodule AskDrive.DataModelTest do
  use AskDrive.DataCase
  alias AskDrive.Documents.{Document, Chunk}
  alias AskDrive.QA.QAPair
  alias AskDrive.Settings
  alias AskDrive.Vector

  test "settings context creates and updates singleton settings" do
    setting = Settings.get_setting!()
    assert setting.batch_start_hour == 0
    assert setting.batch_model == "qwen3:4b"

    {:ok, updated} =
      Settings.update_setting(setting, %{batch_start_hour: 22, similarity_threshold: 0.7})

    assert updated.batch_start_hour == 22
    assert updated.similarity_threshold == 0.7
  end

  test "drive_impersonate_email is trimmed, validated, and clearable" do
    setting = Settings.get_setting!()

    {:ok, updated} =
      Settings.update_setting(setting, %{drive_impersonate_email: "  sync@example.com "})

    assert updated.drive_impersonate_email == "sync@example.com"

    assert {:error, changeset} =
             Settings.update_setting(updated, %{drive_impersonate_email: "not-an-email"})

    assert changeset.errors[:drive_impersonate_email]

    {:ok, cleared} = Settings.update_setting(updated, %{drive_impersonate_email: ""})
    assert cleared.drive_impersonate_email == nil
  end

  test "inserts document, chunk, and queries vec_chunks via sqlite-vec" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "test_drive_file_123",
        name: "test_doc.txt",
        mime_type: "text/plain",
        content_hash: "dummy_hash_1"
      })
      |> Repo.insert()

    # Generate 1024 dimensional dummy vector
    dummy_vec1 = for i <- 1..1024, do: if(i == 1, do: 1.0, else: 0.0)
    dummy_vec2 = for i <- 1..1024, do: if(i == 2, do: 1.0, else: 0.0)

    blob1 = Vector.encode(dummy_vec1)
    blob2 = Vector.encode(dummy_vec2)
    vec1_json = Vector.to_json(dummy_vec1)
    vec2_json = Vector.to_json(dummy_vec2)

    {:ok, chunk1} =
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        content: "第一章の本文",
        content_hash: "chunk_hash_1",
        embedding: blob1
      })
      |> Repo.insert()

    {:ok, chunk2} =
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: 1,
        content: "第二章の本文",
        content_hash: "chunk_hash_2",
        embedding: blob2
      })
      |> Repo.insert()

    # Insert into sqlite-vec virtual table
    {:ok, _} =
      Repo.query("INSERT INTO vec_chunks(chunk_id, embedding) VALUES (?, ?)", [
        chunk1.id,
        vec1_json
      ])

    {:ok, _} =
      Repo.query("INSERT INTO vec_chunks(chunk_id, embedding) VALUES (?, ?)", [
        chunk2.id,
        vec2_json
      ])

    # Query KNN for vector close to dummy_vec1
    query_json = Vector.to_json(dummy_vec1)

    query_sql = """
    SELECT chunk_id, distance
    FROM vec_chunks
    WHERE embedding MATCH ? AND k = 2
    ORDER BY distance ASC
    """

    {:ok, %{rows: rows}} = Repo.query(query_sql, [query_json])
    assert [[first_chunk_id, first_dist] | _] = rows
    assert first_chunk_id == chunk1.id
    assert_in_delta first_dist, 0.0, 0.001
  end

  test "cascade deletion deletes chunks and qa_pairs when document is deleted" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "doc_to_delete",
        name: "delete_me.txt",
        mime_type: "text/plain"
      })
      |> Repo.insert()

    {:ok, chunk} =
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        content: "チャンク本文",
        content_hash: "hash_xyz"
      })
      |> Repo.insert()

    {:ok, qa} =
      %QAPair{}
      |> QAPair.changeset(%{
        document_id: doc.id,
        chunk_id: chunk.id,
        question: "質問",
        answer: "回答",
        source_hash: "hash_xyz",
        generated_by: "qwen3:4b"
      })
      |> Repo.insert()

    # Deleting document should cascade
    Repo.delete!(doc)

    assert is_nil(Repo.get(Chunk, chunk.id))
    assert is_nil(Repo.get(QAPair, qa.id))
  end
end
