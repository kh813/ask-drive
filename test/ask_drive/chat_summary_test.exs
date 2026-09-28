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

    assert {:ok, %{text: "USB メモリの接続は禁止です [1]", thinking: "考え中"}} =
             ChatSummary.generate("USBメモリの利用ルールは？", [chunk], &send(test_pid, {:ev, &1}))

    assert_received {:ev, {:answer, "USB メモリの"}}
    assert_received {:ev, {:answer, "接続は禁止です [1]"}}
    assert_received {:ev, {:thinking, "考え中"}}

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

  defp collect(kind, acc \\ []) do
    receive do
      {:ev, {^kind, d}} -> collect(kind, [d | acc])
    after
      0 -> acc |> Enum.reverse()
    end
  end

  test "thinking opened by the chat template (no <think>) is never shown", %{chunk: chunk} do
    StubOllama.put_generate_pieces([
      "Okay, let's tackle this query. ",
      "The user is asking about PC持ち出し...",
      "</think>\n\n",
      "PC の持ち出しは許可制です [1]。"
    ])

    test_pid = self()

    assert {:ok, %{text: "PC の持ち出しは許可制です [1]。", thinking: thinking}} =
             ChatSummary.generate("PC持ち出しのルールは？", [chunk], &send(test_pid, {:ev, &1}))

    assert thinking =~ "Okay, let's tackle this query."
    assert Enum.join(collect(:answer)) == "PC の持ち出しは許可制です [1]。"
    assert Enum.join(collect(:thinking)) =~ "PC持ち出し"
  end

  test "a runaway answer is cut at the display cap and generation is stopped", %{chunk: chunk} do
    StubOllama.put_generate_pieces(List.duplicate("とても長い回答の文章です。", 100))
    test_pid = self()

    assert {:ok, %{text: text}} =
             ChatSummary.generate("PC持ち出しのルールは？", [chunk], &send(test_pid, {:ev, &1}))

    assert String.length(text) == 301
    assert String.ends_with?(text, "…")
    assert String.length(Enum.join(collect(:answer))) == 301
  end

  test "qwen3 prompts carry /no_think; other models don't", %{chunk: chunk} do
    assert ChatSummary.build_prompt("質問", [chunk], "qwen3:4b") =~ "/no_think"
    refute ChatSummary.build_prompt("質問", [chunk], "qwen2.5:3b") =~ "/no_think"
    refute ChatSummary.build_prompt("質問", [chunk], "gemini-flash-latest") =~ "/no_think"
  end

  test "visible_text/3 separates thinking from the answer" do
    assert ChatSummary.visible_text("<think>x</think>答え", true, false) == "答え"
    assert ChatSummary.visible_text("<think>まだ考え中", true, false) == ""
    assert ChatSummary.visible_text("考え中で閉じタグ前", true, false) == ""
    assert ChatSummary.visible_text("考え中で閉じタグ前", true, true) == "考え中で閉じタグ前"
    assert ChatSummary.visible_text("普通の回答", false, false) == "普通の回答"
  end
end
