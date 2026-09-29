defmodule AskDrive.LLM.OllamaGenerateTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.LLM.Providers.Ollama
  alias AskDrive.StubOllama

  setup do
    {server, url} = StubOllama.start!(self())

    on_exit(fn ->
      StubOllama.reject_think(false)
      StubOllama.put_generate_pieces(["要約です。"])
      Process.exit(server, :normal)
    end)

    %{url: url}
  end

  test "non-streaming generate turns thinking off and caps the output when asked", %{url: url} do
    StubOllama.put_generate_pieces(["[]"])

    assert {:ok, "[]"} =
             Ollama.generate("qwen3:4b", "prompt", base_url: url, max_tokens: 1536)

    assert_receive {:stub_generate, body}
    assert body["think"] == false
    assert body["stream"] == false
    assert body["options"]["num_predict"] == 1536
  end

  test "a model without thinking support is asked again without the think field", %{url: url} do
    StubOllama.reject_think(true)
    StubOllama.put_generate_pieces(["ok"])

    assert {:ok, "ok"} = Ollama.generate("gemma", "prompt", base_url: url)
    assert_receive {:stub_generate, %{"think" => false}}
    assert_receive {:stub_generate, body}
    refute Map.has_key?(body, "think")
  end

  test "QA generation for the nightly batch sends think: false and an output cap", %{url: url} do
    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        ollama_host: url,
        llm_provider: "ollama"
      })

    StubOllama.put_generate_pieces([~s([{"question": "申請期限は？", "answer": "月末です。"}])])

    chunk = %AskDrive.Documents.Chunk{id: 1, content: "申請期限は月末です。", document_id: 1}
    AskDrive.Runtime.Mode.set_mode(:night_batch)
    on_exit(fn -> AskDrive.Runtime.Mode.set_mode(:daytime) end)

    assert {:ok, [%{question: "申請期限は？"}]} =
             AskDrive.Generate.QA.generate_for_chunk(chunk, "qwen3:4b")

    assert_receive {:stub_generate, body}
    assert body["think"] == false
    assert body["options"]["num_predict"] == 1536
  end
end
