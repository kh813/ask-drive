defmodule AskDrive.BackupTest do
  use AskDrive.DataCase, async: false
  alias AskDrive.Backup

  describe "SQLite Backup & Maintenance" do
    test "wal_status/0 returns database size and WAL metrics" do
      stat = Backup.wal_status()
      assert is_binary(stat.db_path)
      assert is_integer(stat.db_size_bytes)
      assert is_integer(stat.wal_size_bytes)
      assert is_boolean(stat.wal_warning?)
    end

    test "checkpoint_wal/1 performs PRAGMA wal_checkpoint" do
      assert {:ok, res} = Backup.checkpoint_wal(:passive)
      assert is_boolean(res.busy)
      assert is_integer(res.log_pages)
      assert is_integer(res.checkpointed_pages)
    end

    test "backup_current_db/1 creates a vacuum copy of the database" do
      tmp_dir = System.tmp_dir!()
      dest = Path.join(tmp_dir, "test_backup_#{System.unique_integer([:positive])}.db")
      on_exit(fn -> File.rm(dest) end)

      assert {:ok, ^dest} = Backup.backup_current_db(dest)
      assert File.exists?(dest)
      assert File.stat!(dest).size > 0
    end

    test "backup_all/1 backs up databases and cleans up old ones" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ask_drive_backup_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      assert {:ok, %{backed_up: files, total_bytes: bytes, dir: ^tmp_dir}} =
               Backup.backup_all(tmp_dir)

      assert length(files) >= 1
      assert bytes > 0
      assert Enum.all?(files, &File.exists?/1)
    end
  end
end
