defmodule AskDrive.Documents do
  @moduledoc """
  Context for managing synced documents and chunks.
  """
  import Ecto.Query, warn: false
  alias AskDrive.Repo
  alias AskDrive.Documents.Document
  alias AskDrive.Ingest.FileTypes

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
  Version of the extraction/chunking pipeline (spec F-337). Bump it when a change must reach
  documents already indexed — sync then re-indexes them once even though Drive reports them
  unchanged. Unchanged chunks are still reused (F-336), so this re-embeds little.

    * 1: initial
    * 2: PDF chunks carry their page number (F-411)
  """
  def current_index_version, do: 2

  @doc """
  Upserts a document from Google Drive file metadata.
  Returns `{:created, doc}`, `{:updated, doc}`, `{:unchanged, doc}`, or `{:excluded, doc}`
  for a file that isn't a document (`AskDrive.Ingest.FileTypes`, spec F-356).

  A file already indexed (or deliberately skipped) stays `:unchanged` — no re-extraction or
  re-embedding in the batch — when Drive reports the same `modifiedTime`, or the same
  `md5Checksum` even though `modifiedTime` moved (spec F-334). Metadata such as a new name,
  path or link is still recorded. Failed or pending files are always retried.
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
      md5_checksum: drive_file["md5Checksum"],
      size_bytes: parse_integer(drive_file["size"])
    }

    existing = get_document_by_drive_file_id(drive_id)

    if FileTypes.indexable?(attrs.name, attrs.mime_type),
      do: upsert_indexable(existing, attrs),
      else: upsert_excluded(existing, attrs)
  end

  defp upsert_indexable(existing, attrs) do
    case existing do
      nil ->
        {:ok, doc} =
          %Document{}
          |> Document.changeset(Map.put(attrs, :status, "pending"))
          |> Repo.insert()

        {:created, doc}

      %Document{} = existing ->
        # a file left out for its type that now counts (renamed .txt, a type added) is read
        if existing.status in ["indexed", "skipped"] and same_content?(existing, attrs) and
             existing.index_version >= current_index_version() and
             not FileTypes.excluded_reason?(existing.error) do
          {:ok, doc} = existing |> Document.changeset(attrs) |> Repo.update()
          {:unchanged, doc}
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

  # Not a document (a program, a script, source code): recorded as skipped with the reason,
  # never downloaded. One indexed before the allowlist (F-356) loses its chunks, QA and
  # summaries — it's removed and recorded again as left out.
  defp upsert_excluded(existing, attrs) do
    reason = FileTypes.excluded_reason(attrs.name, attrs.mime_type)

    case existing do
      %Document{status: "skipped", error: ^reason} = doc ->
        {:ok, doc} = doc |> Document.changeset(attrs) |> Repo.update()
        {:excluded, doc}

      _ ->
        if existing, do: AskDrive.Freshness.delete_document_completely(existing)

        {:ok, doc} =
          %Document{}
          |> Document.changeset(attrs |> Map.put(:status, "skipped") |> Map.put(:error, reason))
          |> Repo.insert()

        {:excluded, doc}
    end
  end

  defp same_content?(existing, attrs) do
    same_time? =
      existing.modified_time && attrs.modified_time &&
        DateTime.compare(existing.modified_time, attrs.modified_time) == :eq

    same_md5? =
      is_binary(existing.md5_checksum) and existing.md5_checksum == attrs.md5_checksum

    !!same_time? or same_md5?
  end

  @doc """
  Deletes documents whose drive_file_id is no longer present in current_drive_ids.
  Returns number of deleted documents.
  """
  def delete_missing_documents(current_drive_ids, on_delete \\ fn _doc -> :ok end)
      when is_list(current_drive_ids) do
    missing_docs = Repo.all(from d in Document, where: d.drive_file_id not in ^current_drive_ids)

    Enum.each(missing_docs, fn doc ->
      AskDrive.Freshness.delete_document_completely(doc)
      on_delete.(doc)
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
  The prefix of the reason a document is skipped for when the program that reads it isn't
  installed (`AskDrive.Ingest.Extractor`): `missing_tool_reason("pdftotext")`.
  """
  def missing_tool_reason(tool), do: "Missing external CLI tool: #{tool}"

  @doc """
  Documents skipped because `tool` wasn't installed go back to "pending", so the next
  ingestion reads them now that it is (F-839). Unchanged files are otherwise never read
  again. Returns how many, in the current app's database.
  """
  def requeue_missing_tool(tool) do
    prefix = missing_tool_reason(tool)

    {count, _} =
      Repo.update_all(
        from(d in Document, where: d.status == "skipped" and like(d.error, ^"#{prefix}%")),
        set: [status: "pending", error: nil]
      )

    count
  end

  @doc """
  Marks a document as indexed with content hash.
  """
  def mark_indexed(%Document{} = doc, content_hash) do
    doc
    |> Document.changeset(%{
      status: "indexed",
      content_hash: content_hash,
      index_version: current_index_version(),
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
