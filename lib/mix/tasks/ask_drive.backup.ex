defmodule Mix.Tasks.AskDrive.Backup do
  @shortdoc "Creates an online backup of SQLite databases or checks WAL status"

  @moduledoc """
  SQLite online backup and WAL maintenance CLI task:

      mix ask_drive.backup                 # Back up all databases to default directory
      mix ask_drive.backup /path/to/dir    # Back up to a custom directory
      mix ask_drive.backup status          # Show database & WAL file sizes
      mix ask_drive.backup checkpoint      # Flush WAL pages to main database

  Uses SQLite's `VACUUM INTO` for consistent zero-downtime online snapshots.
  """
  use Mix.Task

  alias AskDrive.Backup

  @impl Mix.Task
  def run(args), do: AskDrive.CliTask.run(fn -> run_task(args) end)

  defp run_task(["status"]) do
    stat = Backup.wal_status()
    Mix.shell().info("=== SQLite & WAL 状態 ===")
    Mix.shell().info("  DB パス: #{stat.db_path} (#{div(stat.db_size_bytes, 1024)} KB)")
    Mix.shell().info("  WAL パス: #{stat.wal_path} (#{div(stat.wal_size_bytes, 1024)} KB)")

    if stat.wal_warning? do
      Mix.shell().info("  [!] 警告: WAL ファイルが 50MB を超えています。checkpoint を推奨します。")
    else
      Mix.shell().info("  [✓] WAL サイズ正常")
    end
  end

  defp run_task(["checkpoint"]) do
    Mix.shell().info("WAL チェックポイント (TRUNCATE) を実行中...")

    case Backup.checkpoint_wal(:truncate) do
      {:ok, res} ->
        Mix.shell().info(
          "WAL チェックポイント完了 (ログページ: #{res.log_pages}, チェックポイント済み: #{res.checkpointed_pages})"
        )

      {:error, reason} ->
        Mix.raise("チェックポイントに失敗しました: #{inspect(reason)}")
    end
  end

  defp run_task([target_dir]) do
    do_backup(target_dir)
  end

  defp run_task([]) do
    do_backup(nil)
  end

  defp do_backup(dir) do
    Mix.shell().info("SQLite オンラインバックアップを実行中 (VACUUM INTO)...")

    case Backup.backup_all(dir) do
      {:ok, %{backed_up: files, total_bytes: bytes, dir: out_dir}} ->
        Mix.shell().info("バックアップが完了しました。")
        Mix.shell().info("  保存先: #{out_dir}")
        Mix.shell().info("  ファイル数: #{length(files)} (#{div(bytes, 1024)} KB)")
        Enum.each(files, fn f -> Mix.shell().info("    - #{Path.basename(f)}") end)

      {:error, reason} ->
        Mix.raise("バックアップに失敗しました: #{inspect(reason)}")
    end
  end
end
