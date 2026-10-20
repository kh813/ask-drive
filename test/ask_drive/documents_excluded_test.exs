defmodule AskDrive.DocumentsExcludedTest do
  @moduledoc """
  Sync records a file that isn't a document as skipped, with the reason, and never queues it
  for ingestion; one indexed before (F-356) loses its chunks; one renamed into a document
  type is read again.
  """
  use AskDrive.DataCase
  alias AskDrive.Documents
  alias AskDrive.Documents.{Chunk, Document}

  defp file(name, mime, id \\ "f-py") do
    %{
      "id" => id,
      "name" => name,
      "mimeType" => mime,
      "modifiedTime" => "2026-10-01T00:00:00.000Z"
    }
  end

  test "a program or source file is recorded as skipped, not queued" do
    assert {:excluded, doc} =
             Documents.upsert_document_from_drive(file("tool.py", "text/x-python"))

    assert doc.status == "skipped"
    assert doc.error =~ ".py"

    # unchanged in Drive: stays as it is
    assert {:excluded, again} =
             Documents.upsert_document_from_drive(file("tool.py", "text/x-python"))

    assert again.id == doc.id
  end

  test "a source file indexed before loses its chunks" do
    # indexed under the old rules (no allowlist then)
    doc =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "f-py",
        name: "tool.py",
        mime_type: "text/plain",
        status: "indexed"
      })
      |> Repo.insert!()

    %Chunk{}
    |> Chunk.changeset(%{
      document_id: doc.id,
      content: "print(1)",
      position: 0,
      content_hash: "h"
    })
    |> Repo.insert!()

    assert {:excluded, now} = Documents.upsert_document_from_drive(file("tool.py", "text/plain"))
    assert now.status == "skipped"
    assert Repo.aggregate(Chunk, :count) == 0
    assert Repo.aggregate(Document, :count) == 1
  end

  test "a file left out that becomes a document is read again" do
    {:excluded, _} = Documents.upsert_document_from_drive(file("notes", "application/x-foo"))

    assert {:updated, doc} = Documents.upsert_document_from_drive(file("notes.txt", "text/plain"))
    assert doc.status == "pending"
    assert doc.error == nil
  end
end
