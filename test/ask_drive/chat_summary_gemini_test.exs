defmodule AskDrive.ChatSummaryGeminiTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.{ChatSummary, Settings, StubGemini}
  alias AskDrive.Documents.{Chunk, Document}

  test "chat summary on Gemini: streamed, reasoning off, answer only" do
    {server, url} = StubGemini.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{
        chat_summary_provider: "gemini",
        chat_summary_model: "gemini-flash-latest",
        gemini_api_key: "k",
        gemini_base_url: url
      })

    StubGemini.set(:parts, [
      %{"text" => "Let me think", "thought" => true},
      %{"text" => "USB メモリの接続は禁止です [1]。"}
    ])

    chunk = %Chunk{content: "USB メモリの接続を禁止する。", page: 3, document: %Document{name: "g.pdf"}}
    test_pid = self()

    assert {:ok, %{text: "USB メモリの接続は禁止です [1]。", thinking: ""}} =
             ChatSummary.generate("USBメモリの利用ルールは？", [chunk], &send(test_pid, {:ev, &1}))

    assert_received {:stub_gemini, "gemini-flash-latest:streamGenerateContent", body}
    assert body["generationConfig"]["thinkingConfig"] == %{"thinkingBudget" => 0}
    assert body["generationConfig"]["maxOutputTokens"] == 450
    assert body["systemInstruction"]
    refute body["contents"] |> hd() |> get_in(["parts", Access.at(0), "text"]) =~ "/no_think"
    assert_received {:ev, {:answer, "USB メモリの接続は禁止です [1]。"}}
  end

  test "nightly QA generation on Gemini (cloud mode) parses the JSON answer, even fenced" do
    {server, url} = StubGemini.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    {:ok, setting} =
      Settings.update_setting(Settings.get_setting!(), %{
        batch_llm_mode: "cloud",
        cloud_llm_provider: "gemini",
        cloud_llm_model: "gemini-flash-latest",
        gemini_api_key: "k",
        gemini_base_url: url
      })

    json = ~s([{"question": "USBメモリは使えますか？", "answer": "会社貸与品のみ使えます。"}])
    StubGemini.set(:parts, [%{"text" => "```json\n" <> json <> "\n```"}])

    chunk = %Chunk{
      id: 1,
      content: "USBメモリは会社貸与品のみ使える。",
      content_hash: "h",
      document_id: 1
    }

    AskDrive.Runtime.Mode.set_mode(:daytime)

    assert {:ok, [%{question: "USBメモリは使えますか？"} | _]} =
             AskDrive.Generate.QA.generate_for_chunk(
               chunk,
               AskDrive.LLM.generation_model(setting)
             )

    assert_received {:stub_gemini, "gemini-flash-latest:generateContent", _}
  end
end
