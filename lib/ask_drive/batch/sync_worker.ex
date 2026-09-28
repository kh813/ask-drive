defmodule AskDrive.Batch.SyncWorker do
  @moduledoc """
  Oban worker for synchronizing Google Drive folder metadata and detecting changes.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3

  require Logger
  alias AskDrive.{Accounts, Documents, Settings}
  alias AskDrive.Batch.ItemLog
  alias AskDrive.Drive.Client, as: DriveClient

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    run_id = args["batch_run_id"]

    if Accounts.drive_connected?() do
      folder_id = args["folder_id"] || get_target_folder_id()

      if is_nil(folder_id) or folder_id == "" do
        Logger.warning("SyncWorker: No Drive folder ID configured.")
        log_folder_failure(run_id, nil, "同期フォルダが設定されていません")
        {:ok, :no_folder_configured}
      else
        run_sync(folder_id, run_id)
      end
    else
      Logger.error(
        "SyncWorker: Drive is not connected (neither OAuth account nor service account configured)."
      )

      log_folder_failure(run_id, nil, "Drive 連携が未設定です（OAuth / サービスアカウントのいずれも未設定）")
      {:error, :not_connected}
    end
  end

  defp log_folder_failure(run_id, folder_id, message) do
    ItemLog.record(run_id, %{
      phase: "sync",
      drive_file_id: folder_id,
      name: "（同期フォルダ）",
      status: "failed",
      message: message
    })
  end

  defp get_target_folder_id do
    setting = Settings.get_setting!()
    setting.drive_folder_id
  end

  defp run_sync(folder_id, run_id) do
    Logger.info("SyncWorker: Starting Drive sync for folder #{folder_id}...")

    case DriveClient.list_files(folder_id) do
      {:ok, drive_files} ->
        Logger.info("SyncWorker: Found #{length(drive_files)} files in Drive.")

        stats =
          Enum.reduce(drive_files, %{created: 0, updated: 0, unchanged: 0, failed: 0}, fn file,
                                                                                          acc ->
            try do
              {outcome, doc} = Documents.upsert_document_from_drive(file)

              Logger.info(
                "SyncWorker: #{outcome} #{file["path"] || file["name"]} (#{file["mimeType"]})"
              )

              log_file(run_id, file, doc.id, Atom.to_string(outcome), nil)
              Map.update!(acc, outcome, &(&1 + 1))
            rescue
              e ->
                Logger.error("SyncWorker: Failed to upsert file #{file["id"]}: #{inspect(e)}")
                log_file(run_id, file, nil, "failed", Exception.message(e))
                %{acc | failed: acc.failed + 1}
            end
          end)

        # Remove deleted files from local DB
        current_drive_ids = Enum.map(drive_files, & &1["id"])

        deleted_count =
          Documents.delete_missing_documents(current_drive_ids, fn doc ->
            Logger.info("SyncWorker: deleted #{doc.name} (no longer in Drive folder)")

            ItemLog.record(run_id, %{
              phase: "sync",
              drive_file_id: doc.drive_file_id,
              name: doc.name,
              mime_type: doc.mime_type,
              status: "deleted",
              message: "Drive のフォルダから無くなったため、インデックスから削除しました"
            })
          end)

        result =
          stats
          |> Map.put(:total_drive_files, length(drive_files))
          |> Map.put(:deleted, deleted_count)

        Logger.info("SyncWorker finished: #{inspect(result)}")
        {:ok, result}

      {:error, reason} ->
        Logger.error("SyncWorker failed to list files: #{inspect(reason)}")
        log_folder_failure(run_id, folder_id, "フォルダを一覧できません: " <> ItemLog.describe_reason(reason))
        {:error, reason}
    end
  end

  defp log_file(run_id, file, document_id, status, message) do
    ItemLog.record(run_id, %{
      phase: "sync",
      document_id: document_id,
      drive_file_id: file["id"],
      name: file["path"] || file["name"],
      mime_type: file["mimeType"],
      status: status,
      message: message
    })
  end
end
