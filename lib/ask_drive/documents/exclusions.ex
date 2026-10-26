defmodule AskDrive.Documents.Exclusions do
  @moduledoc """
  Files and folders a desk leaves out of the nightly batch (spec F-358): old versions,
  drafts, rosters or anything else in the sync folder that shouldn't answer questions, and
  files AskDrive writes there itself (an exported FAQ sheet).

  Kept by Drive ID, never by name, so renaming a file neither brings it back nor takes a
  look-alike out. An excluded file is never downloaded and stays in the documents list as
  skipped, with the reason; an excluded folder isn't even listed, so whatever is below it
  leaves the index. Either way its chunks, QA pairs and summaries go at once — answers stop
  using it before the next batch — and the next sync keeps it out. Removing an exclusion
  brings the file or folder back in the next batch.

  Changes are refused while this desk's batch runs: it may be reading the very document.
  """
  import Ecto.Query, warn: false
  require Logger

  alias AskDrive.{Documents, Freshness, Repo}
  alias AskDrive.Batch.Scheduler
  alias AskDrive.Documents.{Document, Exclusion}
  alias AskDrive.Drive.{Client, Url}

  @folder_mime "application/vnd.google-apps.folder"

  @admin_reason "Excluded from the index by an administrator (documents tab)"
  @system_reason "Excluded from the index: a file AskDrive writes itself"

  # --- Reading ------------------------------------------------------------------

  @doc "This desk's exclusions: AskDrive's own first, then the newest first."
  def list do
    Repo.all(from e in Exclusion, order_by: [desc: e.source, desc: e.inserted_at, desc: e.id])
  end

  @doc "The excluded files, as `%{drive_id => source}` (what sync passes to the upsert)."
  def files do
    Repo.all(from e in Exclusion, where: e.kind == "file", select: {e.drive_id, e.source})
    |> Map.new()
  end

  @doc "The excluded folders."
  def folders, do: Repo.all(from e in Exclusion, where: e.kind == "folder")

  @doc "The reason recorded on a document an exclusion of this source leaves out."
  def reason("system"), do: @system_reason
  def reason(_admin), do: @admin_reason

  @doc "Whether a document's recorded reason says it was excluded (so it's read again once not)."
  def reason?(reason) when is_binary(reason), do: reason in [@admin_reason, @system_reason]
  def reason?(_), do: false

  @doc "Whether a document sits in an excluded `folder` (by its folder IDs, or its path)."
  def in_folder?(%Document{} = doc, %Exclusion{kind: "folder"} = folder) do
    folder.drive_id in (doc.folder_ids || []) or
      (is_binary(folder.path) and is_binary(doc.path) and
         String.starts_with?(doc.path, folder.path <> "/"))
  end

  def in_folder?(_doc, _exclusion), do: false

  # --- Changing -------------------------------------------------------------------

  @doc """
  Leaves a file or folder out (an administrator, from the documents tab):
  `attrs` has `:drive_id`, `:kind`, and `:name` / `:path` when known. Takes it out of the
  index at once. Returns `{:ok, exclusion, removed_documents}` or `{:error, reason}`:
  `:batch_running`, `:sync_folder` (the desk's own folder), `:already_excluded`.
  """
  def exclude(attrs, by) do
    attrs = Map.new(attrs)

    cond do
      Scheduler.running?() -> {:error, :batch_running}
      attrs[:drive_id] == sync_folder_id() -> {:error, :sync_folder}
      true -> insert_and_apply(Map.merge(attrs, %{source: "admin", excluded_by: by}))
    end
  end

  @doc """
  Leaves out a file AskDrive writes into the sync folder itself (an exported FAQ sheet):
  kept out whatever an administrator does, and not removable from the screen.
  """
  def exclude_system(drive_id, name) do
    case Repo.get_by(Exclusion, drive_id: drive_id) do
      %Exclusion{source: "system"} = existing ->
        {:ok, existing, 0}

      existing ->
        if existing, do: Repo.delete!(existing)

        insert_and_apply(%{
          drive_id: drive_id,
          kind: "file",
          name: name,
          source: "system",
          excluded_by: "AskDrive"
        })
    end
  end

  @doc """
  Takes an administrator's exclusion back. A file goes back in line for the next batch; a
  folder's documents come back when the next sync lists them again. AskDrive's own can't be
  removed. Returns `{:ok, exclusion}` or `{:error, :batch_running | :system | :not_found}`.
  """
  def remove(id) do
    case Repo.get(Exclusion, id) do
      nil ->
        {:error, :not_found}

      %Exclusion{source: "system"} ->
        {:error, :system}

      %Exclusion{} = exclusion ->
        if Scheduler.running?() do
          {:error, :batch_running}
        else
          Repo.delete!(exclusion)
          if exclusion.kind == "file", do: requeue_file(exclusion.drive_id)
          {:ok, exclusion}
        end
    end
  end

  @doc """
  What a Drive URL or ID points at, for excluding it from the screen:
  `{:ok, %{drive_id:, kind:, name:, path:}}` or `{:error, reason}`.
  """
  def resolve(input) do
    with {:ok, %{id: id}} <- Url.parse(input),
         {:ok, meta} <- Client.get_metadata(id) do
      kind = if meta["mimeType"] == @folder_mime, do: "folder", else: "file"
      {:ok, %{drive_id: id, kind: kind, name: meta["name"], path: known_path(id, kind)}}
    end
  end

  # --- Internals --------------------------------------------------------------------

  defp insert_and_apply(attrs) do
    case %Exclusion{} |> Exclusion.changeset(attrs) |> Repo.insert() do
      {:ok, exclusion} ->
        removed = apply_now(exclusion)

        Logger.info(
          "Exclusions: #{exclusion.kind} #{exclusion.name || exclusion.drive_id} excluded"
        )

        {:ok, exclusion, removed}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :drive_id),
          do: {:error, :already_excluded},
          else: {:error, changeset}
    end
  end

  # out of the index now, not only from the next batch on
  defp apply_now(%Exclusion{kind: "file"} = exclusion) do
    case Documents.get_document_by_drive_file_id(exclusion.drive_id) do
      nil ->
        0

      doc ->
        Documents.exclude_document(doc, reason(exclusion.source))
        1
    end
  end

  # what is below the folder leaves the list too: the next sync won't list it
  defp apply_now(%Exclusion{kind: "folder"} = exclusion) do
    docs = Document |> Repo.all() |> Enum.filter(&in_folder?(&1, exclusion))
    Enum.each(docs, &Freshness.delete_document_completely/1)
    length(docs)
  end

  defp requeue_file(drive_id) do
    case Documents.get_document_by_drive_file_id(drive_id) do
      %Document{error: error} = doc ->
        if reason?(error) do
          doc |> Document.changeset(%{status: "pending", error: nil}) |> Repo.update()
        end

      nil ->
        :ok
    end
  end

  defp sync_folder_id, do: AskDrive.Settings.get_setting!().drive_folder_id

  # a document's path, or a folder's from a document below it
  defp known_path(id, "file") do
    case Documents.get_document_by_drive_file_id(id) do
      %Document{path: path} -> path
      nil -> nil
    end
  end

  defp known_path(id, "folder") do
    Document
    |> Repo.all()
    |> Enum.find_value(fn doc ->
      Enum.find_value(Documents.ancestor_folders(doc), &(&1.id == id && &1.path))
    end)
  end
end
