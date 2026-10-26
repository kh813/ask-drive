defmodule AskDrive.Documents.ExclusionsTest do
  @moduledoc """
  Files and folders a desk leaves out of the nightly batch (F-358): out of the index at once,
  kept out by the next sync, back in line once the exclusion is removed.
  """
  use AskDrive.DataCase, async: false

  alias AskDrive.{Documents, Settings}
  alias AskDrive.Batch.BatchRun
  alias AskDrive.Documents.{Chunk, Document, Exclusions}

  defp indexed_doc!(attrs) do
    doc =
      %Document{}
      |> Document.changeset(
        Map.merge(
          %{mime_type: "application/pdf", status: "indexed", content_hash: "c"},
          attrs
        )
      )
      |> Repo.insert!()

    %Chunk{}
    |> Chunk.changeset(%{document_id: doc.id, content: "本文", position: 0, content_hash: "h"})
    |> Repo.insert!()

    doc
  end

  defp drive_file(id, name, folder_ids \\ []) do
    %{
      "id" => id,
      "name" => name,
      "mimeType" => "application/pdf",
      "modifiedTime" => "2026-10-01T00:00:00.000Z",
      "path" => "/共有/" <> name,
      "folder_ids" => folder_ids
    }
  end

  test "a file left out leaves the index now, stays out on sync, and comes back once removed" do
    doc = indexed_doc!(%{drive_file_id: "f1", name: "旧手順.pdf", path: "/共有/旧手順.pdf"})

    assert {:ok, ex, 1} =
             Exclusions.exclude(
               %{drive_id: "f1", kind: "file", name: doc.name, path: doc.path},
               "boss@example.com"
             )

    assert ex.source == "admin" and ex.excluded_by == "boss@example.com"
    assert Repo.aggregate(Chunk, :count) == 0
    now = Documents.get_document_by_drive_file_id("f1")
    assert now.status == "skipped" and Exclusions.reason?(now.error)

    # the next sync keeps it out without downloading it
    assert {:excluded, again} =
             Documents.upsert_document_from_drive(drive_file("f1", "旧手順.pdf"), Exclusions.files())

    assert again.status == "skipped"

    # removed: in line for the next batch, and sync reads it
    assert {:ok, _} = Exclusions.remove(ex.id)
    assert Documents.get_document_by_drive_file_id("f1").status == "pending"

    assert {outcome, back} =
             Documents.upsert_document_from_drive(drive_file("f1", "旧手順.pdf"), Exclusions.files())

    assert outcome in [:updated, :unchanged] and back.status == "pending"
  end

  test "a folder takes what is below it, by folder ID or by path" do
    inside =
      indexed_doc!(%{
        drive_file_id: "a",
        name: "a.pdf",
        path: "/共有/旧版/a.pdf",
        folder_ids: ["old"]
      })

    # synced before folder IDs were recorded: matched by its path
    legacy = indexed_doc!(%{drive_file_id: "b", name: "b.pdf", path: "/共有/旧版/2024/b.pdf"})

    outside =
      indexed_doc!(%{
        drive_file_id: "c",
        name: "c.pdf",
        path: "/共有/最新/c.pdf",
        folder_ids: ["new"]
      })

    assert {:ok, _ex, 2} =
             Exclusions.exclude(
               %{drive_id: "old", kind: "folder", name: "旧版", path: "/共有/旧版"},
               "boss@example.com"
             )

    refute Repo.get(Document, inside.id)
    refute Repo.get(Document, legacy.id)
    assert Repo.get(Document, outside.id)
    assert MapSet.new(Exclusions.folders(), & &1.drive_id) == MapSet.new(["old"])
  end

  test "a document's folders line up with the names in its path" do
    doc = %Document{path: "/共有/人事/旧版/a.pdf", folder_ids: ["hr", "old"]}

    assert [
             %{id: "hr", name: "人事", path: "/共有/人事"},
             %{id: "old", name: "旧版", path: "/共有/人事/旧版"}
           ] = Documents.ancestor_folders(doc)

    # a "/" in a folder name: they don't line up, so none are offered
    assert Documents.ancestor_folders(%Document{path: "/共有/A/B/a.pdf", folder_ids: ["x"]}) == []
    assert Documents.ancestor_folders(%Document{path: "/共有/a.pdf", folder_ids: nil}) == []
  end

  test "refuses the sync folder, a second time, and changes while the batch runs" do
    {:ok, _} = Settings.update_setting(Settings.get_setting!(), %{drive_folder_id: "root"})

    assert {:error, :sync_folder} =
             Exclusions.exclude(%{drive_id: "root", kind: "folder"}, "boss@example.com")

    assert {:ok, ex, 0} = Exclusions.exclude(%{drive_id: "x", kind: "file"}, "boss@example.com")
    assert {:error, :already_excluded} = Exclusions.exclude(%{drive_id: "x", kind: "file"}, nil)

    Repo.insert!(%BatchRun{status: "running", started_at: DateTime.utc_now(:second)})
    assert {:error, :batch_running} = Exclusions.exclude(%{drive_id: "y", kind: "file"}, nil)
    assert {:error, :batch_running} = Exclusions.remove(ex.id)
  end

  test "AskDrive's own files are kept out and can't be removed" do
    doc = indexed_doc!(%{drive_file_id: "faq", name: "AskDrive_FAQ"})
    assert {:ok, ex, 1} = Exclusions.exclude_system("faq", "AskDrive_FAQ")
    assert {:ok, ^ex, 0} = Exclusions.exclude_system("faq", "AskDrive_FAQ")
    assert {:error, :system} = Exclusions.remove(ex.id)

    assert Documents.get_document_by_drive_file_id(doc.drive_file_id).error ==
             Exclusions.reason("system")
  end
end
