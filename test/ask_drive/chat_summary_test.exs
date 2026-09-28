defmodule AskDrive.ChatSummaryTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.ChatSummary
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.{Settings, StubOllama}

  setup do
    {server, url} = StubOllama.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{ollama_host: url, llm_provider: "ollama"})

    chunk = %Chunk{
      content: "[文書: ガイドライン.pdf]\nじ じ\nUSB メモリ、外付け HDD も接続を禁止する。",
      page: 33,
      document: %Document{name: "ガイドライン.pdf"}
    }

    %{chunk: chunk}
  end

  test "streams the provider's answer piece by piece and returns the whole text", %{chunk: chunk} do
    StubOllama.put_generate_pieces(["<think>考え中</think>", "USB メモリの", "接続は禁止です [1]"])
    test_pid = self()

    assert {:ok, "USB メモリの接続は禁止です [1]"} =
             ChatSummary.generate("USBメモリの利用ルールは？", [chunk], &send(test_pid, {:delta, &1}))

    assert_received {:delta, "USB メモリの"}
    assert_received {:delta, "接続は禁止です [1]"}

    assert_received {:stub_generate, body}
    assert body["stream"] == true
    assert body["think"] == false
    # the length cap reaches Ollama as num_predict
    assert body["options"]["num_predict"] == 450
  end

  test "the prompt numbers the excerpts with their source and page, cleaned", %{chunk: chunk} do
    prompt = ChatSummary.build_prompt("USBメモリの利用ルールは？", [chunk])

    assert prompt =~ "[1] ガイドライン.pdf p.33"
    assert prompt =~ "USB メモリ、外付け HDD も接続を禁止する。"
    refute prompt =~ "じ じ"
    refute prompt =~ "[文書:"
    assert prompt =~ "資料からは確認できませんでした"
    assert prompt =~ "必ず日本語で答えてください"
    assert prompt =~ "250字以内"
  end

  test "an English question gets an English prompt with a word budget", %{chunk: chunk} do
    prompt = ChatSummary.build_prompt("What are the rules for USB drives?", [chunk])
    assert prompt =~ "Answer in the same language as the question"
    assert prompt =~ "under 150 words"
    refute prompt =~ "必ず日本語"
  end

  test "chat can use its own provider/model while the batch stays local" do
    setting = Settings.get_setting!()
    assert ChatSummary.provider_and_model(setting) == {"ollama", setting.batch_model}

    assert {:error, cs} = Settings.update_setting(setting, %{chat_summary_provider: "gemini"})
    assert cs.errors[:gemini_api_key]
    assert cs.errors[:chat_summary_model]

    {:ok, updated} =
      Settings.update_setting(setting, %{
        chat_summary_provider: "gemini",
        chat_summary_model: "gemini-flash-latest",
        gemini_api_key: "test-key"
      })

    assert ChatSummary.provider_and_model(updated) == {"gemini", "gemini-flash-latest"}
    assert updated.llm_provider == "ollama"
  end
end
