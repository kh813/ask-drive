defmodule AskDrive.LLM.OllamaModelsTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.{ChatSummary, Settings, StubOllama}
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.LLM.OllamaModels

  setup do
    {server, url} = StubOllama.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)
    Phoenix.PubSub.subscribe(AskDrive.PubSub, OllamaModels.topic())

    {:ok, setting} =
      Settings.update_setting(Settings.get_setting!(), %{
        ollama_host: url,
        llm_provider: "ollama",
        embed_provider: "ollama",
        chat_summary_model: "qwen3:4b-instruct-2507-q4_K_M"
      })

    %{setting: setting}
  end

  test "required/1 lists the Ollama models the settings use", %{setting: setting} do
    assert OllamaModels.required(setting) == [
             {"埋め込み", setting.embed_model},
             {"夜間バッチ（QA 生成）", setting.batch_model},
             {"チャット要約", "qwen3:4b-instruct-2507-q4_K_M"}
           ]
  end

  test "installed?/2 treats a missing tag as :latest" do
    assert OllamaModels.installed?("bge-m3", ["bge-m3:latest"])
    refute OllamaModels.installed?("qwen3:4b-instruct-2507-q4_K_M", ["qwen3:4b"])
  end

  test "ensure_required/1 pulls exactly the missing models, reporting progress", %{
    setting: setting
  } do
    StubOllama.put_installed(["#{setting.embed_model}:latest", setting.batch_model])

    assert {:ok, ["qwen3:4b-instruct-2507-q4_K_M"]} = OllamaModels.ensure_required(setting)
    assert_receive {:stub_pull, "qwen3:4b-instruct-2507-q4_K_M"}, 2_000
    assert_receive {:ollama_pulls, %{"qwen3:4b-instruct-2507-q4_K_M" => %{status: "done"}}}, 2_000

    assert {:ok, []} = OllamaModels.ensure_required(setting)
  end

  test "a chat model that isn't pulled yet falls back to the batch model and starts its pull",
       %{setting: setting} do
    StubOllama.put_installed([setting.batch_model])
    StubOllama.put_generate_pieces(["要約です [1]。"])

    chunk = %Chunk{content: "本文", page: 1, document: %Document{name: "a.pdf"}}
    assert {:ok, %{text: "要約です [1]。"}} = ChatSummary.generate("質問は？", [chunk])

    assert_receive {:stub_generate, %{"model" => model}}, 2_000
    assert model == setting.batch_model
    assert_receive {:stub_pull, "qwen3:4b-instruct-2507-q4_K_M"}, 2_000
  end
end
