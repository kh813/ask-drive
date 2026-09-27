defmodule AskDrive.DocumentsTest do
  use AskDrive.DataCase
  alias AskDrive.Documents
  alias AskDrive.Documents.Document

  test "upsert_document_from_drive handles created, unchanged, and updated files" do
    file_payload = %{
      "id" => "drive_file_001",
      "name" => "社内規定.pdf",
      "mimeType" => "application/pdf",
      "path" => "/総務/社内規定.pdf",
      "webViewLink" => "https://drive.google.com/file/d/drive_file_001/view",
      "modifiedTime" => "2026-09-28T05:00:00.000Z",
      "size" => "1048576"
    }

    # 1. First upsert -> created
    assert {:created, %Document{} = doc} = Documents.upsert_document_from_drive(file_payload)
    assert doc.status == "pending"
    assert doc.name == "社内規定.pdf"

    # Mark as indexed
    {:ok, indexed_doc} = Documents.mark_indexed(doc, "hash_12345")
    assert indexed_doc.status == "indexed"

    # 2. Second upsert with identical modifiedTime -> unchanged
    assert {:unchanged, %Document{}} = Documents.upsert_document_from_drive(file_payload)

    # 3. Third upsert with updated modifiedTime -> updated (resets status to pending)
    updated_payload = Map.put(file_payload, "modifiedTime", "2026-09-28T07:00:00.000Z")

    assert {:updated, %Document{} = updated_doc} =
             Documents.upsert_document_from_drive(updated_payload)

    assert updated_doc.status == "pending"
  end

  test "delete_missing_documents removes files that no longer exist in Drive" do
    file1 = %{"id" => "f1", "name" => "1.txt", "mimeType" => "text/plain"}
    file2 = %{"id" => "f2", "name" => "2.txt", "mimeType" => "text/plain"}

    {:created, _} = Documents.upsert_document_from_drive(file1)
    {:created, _} = Documents.upsert_document_from_drive(file2)

    assert length(Documents.list_documents()) == 2

    # Only f1 is in current drive -> f2 is deleted
    deleted_count = Documents.delete_missing_documents(["f1"])
    assert deleted_count == 1
    assert length(Documents.list_documents()) == 1
    assert Documents.get_document_by_drive_file_id("f1") != nil
    assert Documents.get_document_by_drive_file_id("f2") == nil
  end
end
