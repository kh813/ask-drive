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
    # structured output keeps the model from emitting JSON the parser can't read
    assert %{"type" => "array", "items" => %{"required" => ["question", "answer"]}} =
             body["format"]
  end

  test "a model without thinking support is asked again with the same schema", %{url: url} do
    StubOllama.reject_think(true)
    StubOllama.put_generate_pieces(["[]"])
    schema = %{type: "array"}

    assert {:ok, "[]"} = Ollama.generate("gemma", "prompt", base_url: url, json_schema: schema)
    assert_receive {:stub_generate, %{"think" => false, "format" => %{"type" => "array"}}}
    assert_receive {:stub_generate, body}
    refute Map.has_key?(body, "think")
    assert body["format"] == %{"type" => "array"}
  end

  test "generate sends no format unless a schema is given", %{url: url} do
    StubOllama.put_generate_pieces(["ok"])
    assert {:ok, "ok"} = Ollama.generate("qwen3:4b", "prompt", base_url: url)
    assert_receive {:stub_generate, body}
    refute Map.has_key?(body, "format")
  end

  describe "QA generation when the model's JSON is broken" do
    setup %{url: url} do
      {:ok, _} =
        AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
          ollama_host: url,
          llm_provider: "ollama"
        })

      AskDrive.Runtime.Mode.set_mode(:night_batch)
      on_exit(fn -> AskDrive.Runtime.Mode.set_mode(:daytime) end)

      %{chunk: %AskDrive.Documents.Chunk{id: 1, content: "様式は D-11 です。", document_id: 1}}
    end

    @broken ~s([{"question": "様式は？", "answer": "「"D-11"」を使います。"}])

    test "asks again, with the schema, and keeps the good second answer", %{chunk: chunk} do
      StubOllama.put_generate_pieces(
        {:sequence, [[@broken], [~s([{"question": "様式は？", "answer": "D-11 です。"}])]]}
      )

      assert {:ok, [%{answer: "D-11 です。"}]} =
               AskDrive.Generate.QA.generate_for_chunk(chunk, "qwen3:4b")

      assert_receive {:stub_generate, %{"format" => %{"type" => "array"}}}
      assert_receive {:stub_generate, %{"format" => %{"type" => "array"}}}
    end

    @tag :capture_log
    test "fails with a message pointing at where the JSON broke", %{chunk: chunk} do
      StubOllama.put_generate_pieces([@broken])

      assert {:error, "JSON parse failed after retry: " <> message} =
               AskDrive.Generate.QA.generate_for_chunk(chunk, "qwen3:4b")

      assert message =~ ~s(「"⟨ここ⟩D-11)
    end
  end
end
