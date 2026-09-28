defmodule AskDrive.Batch.SyncWorker do
  @moduledoc """
  Oban worker for synchronizing Google Drive folder metadata and detecting changes.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3

  require Logger
  alias AskDrive.{Accounts, Documents, Settings}
  alias AskDrive.Drive.Client, as: DriveClient

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if Accounts.drive_connected?() do
      folder_id = args["folder_id"] || get_target_folder_id()

      if is_nil(folder_id) or folder_id == "" do
        Logger.warning("SyncWorker: No Drive folder ID configured.")
        {:ok, :no_folder_configured}
      else
        run_sync(folder_id)
      end
    else
      Logger.error(
        "SyncWorker: Drive is not connected (neither OAuth account nor service account configured)."
      )

      {:error, :not_connected}
    end
  end

  defp get_target_folder_id do
    setting = Settings.get_setting!()
    setting.drive_folder_id
  end

  defp run_sync(folder_id) do
    Logger.info("SyncWorker: Starting Drive sync for folder #{folder_id}...")

    case DriveClient.list_files(folder_id) do
      {:ok, drive_files} ->
        Logger.info("SyncWorker: Found #{length(drive_files)} files in Drive.")

        stats =
          Enum.reduce(drive_files, %{created: 0, updated: 0, unchanged: 0, failed: 0}, fn file,
                                                                                          acc ->
            try do
              case Documents.upsert_document_from_drive(file) do
                {:created, _doc} -> %{acc | created: acc.created + 1}
                {:updated, _doc} -> %{acc | updated: acc.updated + 1}
                {:unchanged, _doc} -> %{acc | unchanged: acc.unchanged + 1}
              end
            rescue
              e ->
                Logger.error("SyncWorker: Failed to upsert file #{file["id"]}: #{inspect(e)}")
                %{acc | failed: acc.failed + 1}
            end
          end)

        # Remove deleted files from local DB
        current_drive_ids = Enum.map(drive_files, & &1["id"])
        deleted_count = Documents.delete_missing_documents(current_drive_ids)

        result =
          stats
          |> Map.put(:total_drive_files, length(drive_files))
          |> Map.put(:deleted, deleted_count)

        Logger.info("SyncWorker finished: #{inspect(result)}")
        {:ok, result}

      {:error, reason} ->
        Logger.error("SyncWorker failed to list files: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
