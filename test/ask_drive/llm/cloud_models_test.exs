defmodule AskDrive.LLM.CloudModelsTest do
  @moduledoc "The cloud API's model list for the settings screen (spec F-834)."
  use ExUnit.Case, async: false

  alias AskDrive.LLM.CloudModels
  alias AskDrive.Settings.Setting
  alias AskDrive.StubGemini

  @models [
    %{
      "name" => "models/gemini-2.5-flash",
      "displayName" => "Gemini 2.5 Flash",
      "supportedGenerationMethods" => ["generateContent", "countTokens"]
    },
    %{
      "name" => "models/gemini-embedding-001",
      "displayName" => "Gemini Embedding 001",
      "supportedGenerationMethods" => ["embedContent"]
    },
    %{
      "name" => "models/gemini-2.5-flash-preview-tts",
      "displayName" => "Gemini 2.5 Flash TTS",
      "supportedGenerationMethods" => ["generateContent"]
    },
    %{
      "name" => "models/gemini-2.5-pro",
      "displayName" => "Gemini 2.5 Pro",
      "supportedGenerationMethods" => ["generateContent"]
    }
  ]

  setup do
    {server, url} = StubGemini.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)
    StubGemini.set(:models, @models)
    # a fresh key per test, so a list kept by an earlier test is never reused
    key = "k-#{System.unique_integer([:positive])}"
    %{setting: %Setting{gemini_base_url: url, gemini_api_key: key}}
  end

  test "lists only the text generation models, in the API's order", %{setting: setting} do
    assert {:ok, [{"gemini-2.5-flash", "Gemini 2.5 Flash"}, {"gemini-2.5-pro", "Gemini 2.5 Pro"}]} =
             CloudModels.list("gemini", setting)

    assert_received {:stub_gemini, "models", %{"pageSize" => "1000"}}
  end

  test "the list is kept; force asks the provider again", %{setting: setting} do
    assert {:ok, _} = CloudModels.list("gemini", setting)
    assert_received {:stub_gemini, "models", _}

    assert {:ok, _} = CloudModels.list("gemini", setting)
    refute_received {:stub_gemini, "models", _}

    assert {:ok, _} = CloudModels.list("gemini", setting, force: true)
    assert_received {:stub_gemini, "models", _}
  end

  test "without an API key nothing is asked", %{setting: setting} do
    assert {:error, message} = CloudModels.list("gemini", %{setting | gemini_api_key: nil})
    assert message =~ "API"
    refute_received {:stub_gemini, "models", _}
  end

  test "a saved model the provider no longer lists stays selectable" do
    models = [{"gemini-2.5-pro", "Gemini 2.5 Pro"}]

    assert [{"Gemini 2.5 Pro (gemini-2.5-pro)", "gemini-2.5-pro"}] =
             CloudModels.options(models, "gemini-2.5-pro")

    assert [{_kept, "gemini-1.0-pro"}, {_, "gemini-2.5-pro"}] =
             CloudModels.options(models, "gemini-1.0-pro")

    assert [{_, "gemini-2.5-pro"}] = CloudModels.options(models, nil)
  end
end
