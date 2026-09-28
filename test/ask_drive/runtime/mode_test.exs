defmodule AskDrive.Runtime.ModeTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Generate.QA
  alias AskDrive.Runtime.Mode
  alias AskDrive.Settings

  describe "Runtime.Mode transitions and generation guarding" do
    test "set_mode/1 transitions between modes" do
      assert Mode.current_mode() in [:daytime, :standby, :night_batch]

      :ok = Mode.set_mode(:daytime)
      assert Mode.current_mode() == :daytime

      :ok = Mode.set_mode(:standby)
      assert Mode.current_mode() == :standby

      :ok = Mode.set_mode(:night_batch)
      assert Mode.current_mode() == :night_batch
    end

    test "night_batch is held only while a batch runs; end_batch/0 returns to the clock" do
      {:ok, run} =
        %AskDrive.Batch.BatchRun{}
        |> AskDrive.Batch.BatchRun.changeset(%{started_at: DateTime.utc_now(), status: "running"})
        |> AskDrive.Repo.insert()

      :ok = Mode.set_mode(:night_batch)
      assert Mode.sync_with_clock() == :night_batch

      run |> AskDrive.Batch.BatchRun.changeset(%{status: "completed"}) |> AskDrive.Repo.update!()

      resting = Mode.end_batch()
      assert resting in [:daytime, :standby]
      assert Mode.current_mode() == resting
    end

    test "without a running batch the clock never rests in night_batch" do
      :ok = Mode.set_mode(:night_batch)
      assert Mode.sync_with_clock() in [:daytime, :standby]
    end

    test "calculate_current_mode/1 uses the local hour against the batch window (21-7)" do
      assert Mode.calculate_current_mode(~N[2026-09-28 22:30:00]) == :night_batch
      assert Mode.calculate_current_mode(~N[2026-09-29 06:59:00]) == :night_batch
      assert Mode.calculate_current_mode(~N[2026-09-29 10:00:00]) == :daytime
    end

    test "night_window_start_utc/1 is the latest local batch_start_hour" do
      offset = AskDrive.Clock.utc_offset_seconds()

      expected = fn local ->
        local |> NaiveDateTime.add(-offset) |> DateTime.from_naive!("Etc/UTC")
      end

      assert Mode.night_window_start_utc(~N[2026-09-28 23:00:00]) ==
               expected.(~N[2026-09-28 21:00:00])

      assert Mode.night_window_start_utc(~N[2026-09-29 03:00:00]) ==
               expected.(~N[2026-09-28 21:00:00])
    end

    test "generation is disabled during daytime when daytime_llm_enabled is false" do
      setting = Settings.get_setting!()
      Settings.update_setting(setting, %{daytime_llm_enabled: false})

      :ok = Mode.set_mode(:daytime)
      assert {:error, :generation_disabled} = Mode.check_generation_allowed()

      chunk = %AskDrive.Documents.Chunk{
        id: 999,
        document_id: 1,
        position: 0,
        content: "テスト文書の本文です。",
        content_hash: "dummyhash"
      }

      assert {:error, :generation_disabled} = QA.generate_for_chunk(chunk, "qwen3:4b")
    end

    test "generation is allowed during daytime if daytime_llm_enabled is true" do
      setting = Settings.get_setting!()
      Settings.update_setting(setting, %{daytime_llm_enabled: true})

      :ok = Mode.set_mode(:daytime)
      assert :ok = Mode.check_generation_allowed()
    end

    test "generation is allowed in night_batch mode" do
      setting = Settings.get_setting!()
      Settings.update_setting(setting, %{daytime_llm_enabled: false})

      :ok = Mode.set_mode(:night_batch)
      assert :ok = Mode.check_generation_allowed()
    end
  end
end
