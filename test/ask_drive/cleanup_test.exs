defmodule AskDrive.CleanupTest do
  use ExUnit.Case, async: true
  alias AskDrive.Cleanup

  describe "Temporary file cleanup" do
    test "clean_temp_files/1 removes expired ask_drive temporary files" do
      tmp_dir = System.tmp_dir!()

      old_file =
        Path.join(tmp_dir, "ask_drive_tmp_test_old_#{System.unique_integer([:positive])}.pdf")

      File.write!(old_file, "old data")

      # Set old mtime (2 hours ago)
      past_time = {{2020, 1, 1}, {0, 0, 0}}
      :file.change_time(String.to_charlist(old_file), past_time)

      fresh_file =
        Path.join(tmp_dir, "ask_drive_tmp_test_fresh_#{System.unique_integer([:positive])}.pdf")

      File.write!(fresh_file, "fresh data")
      on_exit(fn -> File.rm(fresh_file) end)

      assert {:ok, %{removed_count: count}} = Cleanup.clean_temp_files(3600)
      assert count >= 1
      refute File.exists?(old_file)
      assert File.exists?(fresh_file)
    end
  end
end
