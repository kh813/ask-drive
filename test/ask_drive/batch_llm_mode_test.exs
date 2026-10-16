defmodule AskDrive.BatchLlmModeTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.{ChatSummary, LLM, Settings}

  test "local mode uses llm_provider / batch_model" do
    setting = Settings.get_setting!()
    assert setting.batch_llm_mode == "local"
    assert LLM.generation_provider(setting) == "ollama"
    assert LLM.generation_model(setting) == setting.batch_model
    refute LLM.cloud_mode?(setting)
  end

  test "cloud mode switches the batch (and default chat summary) to the cloud provider/model" do
    {:ok, setting} =
      Settings.update_setting(Settings.get_setting!(), %{
        batch_llm_mode: "cloud",
        cloud_llm_provider: "gemini",
        cloud_llm_model: "gemini-flash-latest",
        gemini_api_key: "test-key"
      })

    assert LLM.cloud_mode?(setting)
    assert LLM.generation_provider(setting) == "gemini"
    assert LLM.generation_model(setting) == "gemini-flash-latest"
    refute LLM.local_generation?(setting)
    assert ChatSummary.provider_and_model(setting) == {"gemini", "gemini-flash-latest"}

    # The local configuration is kept for switching back
    assert setting.llm_provider == "ollama"
    {:ok, back} = Settings.update_setting(setting, %{batch_llm_mode: "local"})
    assert LLM.generation_provider(back) == "ollama"
    assert LLM.generation_model(back) == back.batch_model
  end

  test "cloud mode requires a model name; the API key may come later (F-343)" do
    assert {:error, cs} =
             Settings.update_setting(Settings.get_setting!(), %{
               batch_llm_mode: "cloud",
               cloud_llm_provider: "gemini"
             })

    refute cs.errors[:gemini_api_key]
    assert cs.errors[:cloud_llm_model]
  end

  test "cloud mode can generate outside the night window" do
    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{
        batch_llm_mode: "cloud",
        cloud_llm_provider: "gemini",
        cloud_llm_model: "m",
        gemini_api_key: "k",
        daytime_llm_enabled: false
      })

    AskDrive.Runtime.Mode.set_mode(:daytime)
    assert :ok = AskDrive.Runtime.Mode.check_generation_allowed()
  end
end
