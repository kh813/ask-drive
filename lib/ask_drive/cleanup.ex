defmodule AskDrive.Cleanup do
  @moduledoc """
  Manages cleanup and garbage collection of temporary files, extracted artifacts,
  and expired caches generated during ingestion, OCR, and PDF processing.
  """
  require Logger

  @doc """
  Cleans temporary files matching AskDrive extraction prefixes (`ask_drive_tmp_*`)
  in the system temporary directory older than `max_age_seconds` (default: 1 hour).
  """
  def clean_temp_files(max_age_seconds \\ 3600) do
    tmp_dir = System.tmp_dir!()
    cutoff = System.os_time(:second) - max_age_seconds

    patterns = [
      Path.join(tmp_dir, "ask_drive_tmp_*"),
      Path.join(tmp_dir, "askdrive_setup_*")
    ]

    removed_files =
      patterns
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.reduce(0, fn path, count ->
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime, type: :regular}} when mtime < cutoff ->
            File.rm(path)
            count + 1

          {:ok, %{mtime: mtime, type: :directory}} when mtime < cutoff ->
            # Only remove directory if it is an old setup code dir
            if String.contains?(path, "askdrive_setup_") do
              File.rm_rf(path)
              count + 1
            else
              count
            end

          _ ->
            count
        end
      end)

    if removed_files > 0 do
      Logger.info("Cleanup: removed #{removed_files} expired temporary file(s) from #{tmp_dir}.")
    end

    {:ok, %{removed_count: removed_files, tmp_dir: tmp_dir}}
  end
end
