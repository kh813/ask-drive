defmodule AskDrive.Documents do
  @moduledoc """
  Context for managing synced documents and chunks.
  """
  import Ecto.Query, warn: false
  alias AskDrive.Repo
  alias AskDrive.Documents.Document

  @doc """
  Lists all documents.
  """
  def list_documents do
    Repo.all(from d in Document, order_by: [desc: d.updated_at])
  end

  @doc """
  Gets a single document by ID.
  """
  def get_document!(id), do: Repo.get!(Document, id)

  @doc """
  Gets a single document by Drive file ID.
  """
  def get_document_by_drive_file_id(drive_file_id) do
    Repo.get_by(Document, drive_file_id: drive_file_id)
  end

  @doc """
  Upserts a document from Google Drive file metadata.
  Returns `{:created, doc}`, `{:updated, doc}`, or `{:unchanged, doc}`.
  """
  def upsert_document_from_drive(drive_file) do
    drive_id = drive_file["id"]
    modified_dt = parse_iso_datetime(drive_file["modifiedTime"])

    attrs = %{
      drive_file_id: drive_id,
      name: drive_file["name"] || "Untitled",
      mime_type: drive_file["mimeType"] || "application/octet-stream",
      path: drive_file["path"],
      web_view_link: drive_file["webViewLink"],
      modified_time: modified_dt,
      size_bytes: parse_integer(drive_file["size"])
    }

    case get_document_by_drive_file_id(drive_id) do
      nil ->
        {:ok, doc} =
          %Document{}
          |> Document.changeset(Map.put(attrs, :status, "pending"))
          |> Repo.insert()

        {:created, doc}

      %Document{} = existing ->
        # Check if modified_time changed
        time_matches? =
          existing.modified_time && modified_dt &&
            DateTime.compare(existing.modified_time, modified_dt) == :eq

        if time_matches? and existing.status in ["indexed", "skipped"] do
          {:unchanged, existing}
        else
          {:ok, updated} =
            existing
            |> Document.changeset(
              attrs
              |> Map.put(:status, "pending")
              |> Map.put(:error, nil)
            )
            |> Repo.update()

          {:updated, updated}
        end
    end
  end

  @doc """
  Deletes documents whose drive_file_id is no longer present in current_drive_ids.
  Returns number of deleted documents.
  """
  def delete_missing_documents(current_drive_ids) when is_list(current_drive_ids) do
    missing_docs = Repo.all(from d in Document, where: d.drive_file_id not in ^current_drive_ids)

    Enum.each(missing_docs, fn doc ->
      AskDrive.Freshness.delete_document_completely(doc)
    end)

    length(missing_docs)
  end

  @doc """
  Marks a document as failed with an error message.
  """
  def mark_failed(%Document{} = doc, error_message) do
    doc
    |> Document.changeset(%{
      status: "failed",
      error: to_string(error_message)
    })
    |> Repo.update()
  end

  @doc """
  Marks a document as skipped with an optional reason.
  """
  def mark_skipped(%Document{} = doc, reason) do
    doc
    |> Document.changeset(%{
      status: "skipped",
      error: to_string(reason)
    })
    |> Repo.update()
  end

  @doc """
  Marks a document as indexed with content hash.
  """
  def mark_indexed(%Document{} = doc, content_hash) do
    doc
    |> Document.changeset(%{
      status: "indexed",
      content_hash: content_hash,
      error: nil,
      synced_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Creates a structured extraction item.
  """
  def create_extraction(attrs) do
    %AskDrive.Documents.Extraction{}
    |> AskDrive.Documents.Extraction.changeset(attrs)
    |> Repo.insert()
  end

  defp parse_iso_datetime(nil), do: nil

  defp parse_iso_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(i) when is_integer(i), do: i

  defp parse_integer(str) when is_binary(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> nil
    end
  end
end
