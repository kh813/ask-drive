defmodule AskDrive.LLM.OllamaModelsTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.{ChatSummary, Settings, StubOllama}
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.LLM.OllamaModels

  setup do
    {server, url} = StubOllama.start!(self())
    # pulls finished by earlier tests would show instead of this test's state
    AskDrive.LLM.OllamaModels.reset_pulls()
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

  test "no desk on Ollama: nothing pulled, Ollama not contacted, app.sh told not to start it (F-829)",
       %{setting: setting} do
    dir = Path.join(System.tmp_dir!(), "askdrive_ollama_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:ask_drive, :setup_dir, dir)
    Application.put_env(:ask_drive, :manage_ollama, true)

    on_exit(fn ->
      Application.delete_env(:ask_drive, :setup_dir)
      Application.put_env(:ask_drive, :manage_ollama, false)
      File.rm_rf(dir)
    end)

    {:ok, cloud} =
      Settings.update_setting(setting, %{
        llm_provider: "gemini",
        embed_provider: "gemini",
        chat_summary_provider: "",
        chat_summary_model: ""
      })

    assert OllamaModels.required(cloud) == []
    # the stub answers /api/tags with whatever is installed; it must not even be asked
    StubOllama.put_installed([])
    assert {:ok, :not_used} = OllamaModels.sync_needed(:all)
    assert File.read!(Path.join(dir, "ollama_needed")) == "no\n"
    refute_receive {:stub_pull, _}, 200

    # switched back to Ollama: needed again
    {:ok, local} = Settings.update_setting(cloud, %{embed_provider: "ollama"})
    StubOllama.put_installed(["#{local.embed_model}:latest"])
    assert {:ok, []} = OllamaModels.sync_needed(local)
    assert File.read!(Path.join(dir, "ollama_needed")) == "yes\n"
  end

  test "installed?/2 treats a missing tag as :latest" do
    assert OllamaModels.installed?("bge-m3", ["bge-m3:latest"])
    refute OllamaModels.installed?("qwen3:4b-instruct-2507-q4_K_M", ["qwen3:4b"])
  end

  test "sync_needed/1 reports the missing models and pulls nothing (F-838)", %{
    setting: setting
  } do
    StubOllama.put_installed(["#{setting.embed_model}:latest", setting.batch_model])

    assert {:ok, ["qwen3:4b-instruct-2507-q4_K_M"]} = OllamaModels.sync_needed(setting)
    refute_receive {:stub_pull, _}, 200
  end

  test "a pull (the platform administrator's) reports progress and finishes" do
    OllamaModels.pull_async("qwen3:4b-instruct-2507-q4_K_M")
    assert_receive {:stub_pull, "qwen3:4b-instruct-2507-q4_K_M"}, 2_000
    assert_receive {:ollama_pulls, %{"qwen3:4b-instruct-2507-q4_K_M" => %{status: "done"}}}, 2_000
  end

  test "overview/0: the pulled models, who uses each, and what the desks miss", %{
    setting: setting
  } do
    StubOllama.put_installed(["#{setting.embed_model}:latest", "llama-unused:latest"])

    assert {:ok, %{models: models, missing: missing}} = OllamaModels.overview()

    bge = Enum.find(models, &(&1.name == "#{setting.embed_model}:latest"))
    assert bge.capabilities == ["embedding"]
    assert [{%{slug: "it-support"}, "埋め込み"}] = bge.used_by
    assert Enum.find(models, &(&1.name == "llama-unused:latest")).used_by == []

    assert setting.batch_model in Enum.map(missing, &elem(&1, 2))
    assert "qwen3:4b-instruct-2507-q4_K_M" in Enum.map(missing, &elem(&1, 2))
  end

  test "options/2: only pulled models that can do the job; choosable?/3 for a saved name" do
    models = [
      %{name: "bge-m3:latest", capabilities: ["embedding"]},
      %{name: "qwen3:4b", capabilities: ["completion", "thinking"]},
      %{name: "old:latest", capabilities: []}
    ]

    assert OllamaModels.options(models, :embedding) == [
             {"bge-m3:latest", "bge-m3:latest"},
             {"old:latest", "old:latest"}
           ]

    assert Enum.map(OllamaModels.options(models, :generation), &elem(&1, 1)) ==
             ["qwen3:4b", "old:latest"]

    assert OllamaModels.choosable?(models, :embedding, "bge-m3")
    refute OllamaModels.choosable?(models, :embedding, "qwen3:4b")
    # a cloud API's model name left in an Ollama field
    refute OllamaModels.choosable?(models, :embedding, "gemini-embedding-001")
  end

  test "delete/1 refuses a model a desk uses, and deletes one nobody does", %{setting: setting} do
    StubOllama.put_installed(["#{setting.embed_model}:latest", "llama-unused:latest"])

    assert {:error, {:in_use, ["IT-Support"]}} = OllamaModels.delete(setting.embed_model)
    refute_receive {:stub_delete, _}, 100

    assert :ok = OllamaModels.delete("llama-unused:latest")
    assert_receive {:stub_delete, "llama-unused:latest"}
  end

  test "a chat model that isn't pulled falls back to the batch model, pulling nothing",
       %{setting: setting} do
    StubOllama.put_installed([setting.batch_model])
    StubOllama.put_generate_pieces(["要約です [1]。"])

    chunk = %Chunk{content: "本文", page: 1, document: %Document{name: "a.pdf"}}
    assert {:ok, %{text: "要約です [1]。"}} = ChatSummary.generate("質問は？", [chunk])

    assert_receive {:stub_generate, %{"model" => model}}, 2_000
    assert model == setting.batch_model
    refute_receive {:stub_pull, _}, 200
  end
end
