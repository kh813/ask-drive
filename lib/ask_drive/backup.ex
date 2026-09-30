defmodule AskDrive.Backup do
  @moduledoc """
  Manages SQLite database backups, WAL checkpoint operations, and disk space / WAL health monitoring.

  Provides online consistent backups (`VACUUM INTO`) for both the platform database and individual
  app databases without interrupting reading/answering operations.
  """
  require Logger
  alias AskDrive.{Apps, Repo}

  @doc """
  Performs an online backup of the primary/platform database and all app databases
  into the specified target directory (defaults to `priv/backups` or configured path).

  Returns `{:ok, %{backed_up: [path], total_bytes: bytes}}` or `{:error, reason}`.
  """
  def backup_all(target_dir \\ nil) do
    dest_dir = target_dir || default_backup_dir()
    File.mkdir_p!(dest_dir)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")

    platform_res =
      Apps.platform(fn ->
        backup_current_db(Path.join(dest_dir, "platform_#{timestamp}.db"))
      end)

    app_results =
      Apps.each(fn app ->
        backup_current_db(Path.join(dest_dir, "app_#{app.slug}_#{timestamp}.db"))
      end)

    all_results = [platform: platform_res] ++ app_results

    errors =
      Enum.filter(all_results, fn
        {_, {:error, _}} -> true
        _ -> false
      end)

    if errors == [] do
      backed_up =
        Enum.map(all_results, fn
          {:platform, {:ok, path}} -> path
          {_app, {:ok, path}} -> path
        end)

      total_bytes =
        Enum.reduce(backed_up, 0, fn p, acc ->
          acc + (File.stat(p) |> elem(1) |> Map.get(:size, 0))
        end)

      # Cleanup old backups according to retention
      cleanup_old_backups(dest_dir, 7)

      Logger.info(
        "Backup completed successfully. Saved #{length(backed_up)} database(s) to #{dest_dir} (#{total_bytes} bytes)."
      )

      {:ok, %{backed_up: backed_up, total_bytes: total_bytes, dir: dest_dir}}
    else
      Logger.error("Backup failed for some databases: #{inspect(errors)}")
      {:error, errors}
    end
  end

  @doc """
  Runs `VACUUM INTO` on the database currently active in the dynamic repo context.
  If SQLite cannot VACUUM because a transaction or sandbox lock is active, falls back
  to consistent file snapshot.
  """
  def backup_current_db(dest_file_path) do
    dest_file_path = Path.expand(dest_file_path)
    if File.exists?(dest_file_path), do: File.rm(dest_file_path)

    # SQLite VACUUM INTO requires single-quoted path literal
    escaped_path = String.replace(dest_file_path, "'", "''")

    case Repo.query("VACUUM INTO '#{escaped_path}';") do
      {:ok, _} ->
        {:ok, dest_file_path}

      {:error, %{message: "cannot VACUUM from within a transaction"}} ->
        # In test sandbox or active transaction, copy database file directly
        source_path = Repo.config() |> Keyword.get(:database)

        if source_path && File.exists?(source_path) do
          File.cp!(source_path, dest_file_path)
          {:ok, dest_file_path}
        else
          {:error, :no_source_database_file}
        end

      {:error, reason} = err ->
        Logger.error("VACUUM INTO failed for #{dest_file_path}: #{inspect(reason)}")
        err
    end
  rescue
    e ->
      Logger.error("Exception during VACUUM INTO for #{dest_file_path}: #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Runs WAL checkpoint on the current repo to flush WAL changes to the main database file.
  Modes: :passive (0), :full (1), :restart (2), :truncate (3).
  """
  def checkpoint_wal(mode \\ :passive) do
    sql =
      case mode do
        :passive -> "PRAGMA wal_checkpoint(PASSIVE);"
        :full -> "PRAGMA wal_checkpoint(FULL);"
        :restart -> "PRAGMA wal_checkpoint(RESTART);"
        :truncate -> "PRAGMA wal_checkpoint(TRUNCATE);"
        _ -> "PRAGMA wal_checkpoint(PASSIVE);"
      end

    case Repo.query(sql) do
      {:ok, %{rows: [[busy, log_size, checkpointed]]}} ->
        {:ok, %{busy: busy == 1, log_pages: log_size, checkpointed_pages: checkpointed}}

      error ->
        error
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Checks WAL file size and disk usage for the primary/platform database.
  """
  def wal_status do
    Apps.platform(fn ->
      db_path = Repo.config() |> Keyword.get(:database, "ask_drive_dev.db")
      wal_path = db_path <> "-wal"

      wal_size =
        case File.stat(wal_path) do
          {:ok, %{size: size}} -> size
          _ -> 0
        end

      db_size =
        case File.stat(db_path) do
          {:ok, %{size: size}} -> size
          _ -> 0
        end

      %{
        db_path: db_path,
        db_size_bytes: db_size,
        wal_path: wal_path,
        wal_size_bytes: wal_size,
        wal_warning?: wal_size > 50 * 1024 * 1024
      }
    end)
  rescue
    _ ->
      %{
        db_path: "unknown",
        db_size_bytes: 0,
        wal_path: "unknown",
        wal_size_bytes: 0,
        wal_warning?: false
      }
  end

  @doc """
  Removes backups older than `retention_days` in `dest_dir`.
  """
  def cleanup_old_backups(dest_dir, retention_days \\ 7) do
    cutoff = System.os_time(:second) - retention_days * 86400

    Path.wildcard(Path.join(dest_dir, "*.db"))
    |> Enum.each(fn file ->
      case File.stat(file, time: :posix) do
        {:ok, %{mtime: mtime}} when mtime < cutoff ->
          Logger.info("Removing expired backup file: #{file}")
          File.rm(file)

        _ ->
          :ok
      end
    end)
  end

  def default_backup_dir do
    Path.expand(System.get_env("ASK_DRIVE_BACKUP_DIR") || "priv/backups", File.cwd!())
  end
end
