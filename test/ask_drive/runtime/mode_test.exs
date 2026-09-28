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
