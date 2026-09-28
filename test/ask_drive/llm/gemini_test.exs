defmodule AskDrive.LLM.GeminiTest do
  use ExUnit.Case, async: false

  alias AskDrive.LLM.HTTP
  alias AskDrive.LLM.Providers.Gemini
  alias AskDrive.StubGemini

  setup do
    {server, url} = StubGemini.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)
    %{opts: [base_url: url, api_key: "k"]}
  end

  test "think: false turns reasoning off and thought parts never reach the answer", %{opts: opts} do
    StubGemini.set(:parts, [%{"text" => "考え中", "thought" => true}, %{"text" => "回答です"}])

    assert {:ok, "回答です"} = Gemini.generate("m", "q", opts ++ [think: false, max_tokens: 450])
    assert_received {:stub_gemini, "m:generateContent", body}
    assert body["generationConfig"]["thinkingConfig"] == %{"thinkingBudget" => 0}
    assert body["generationConfig"]["maxOutputTokens"] == 450
  end

  test "streams answer pieces over SSE, skipping thoughts", %{opts: opts} do
    StubGemini.set(:parts, [
      %{"text" => "推論", "thought" => true},
      %{"text" => "USB メモリは"},
      %{"text" => "禁止です [1]"}
    ])

    test_pid = self()

    assert {:ok, "USB メモリは禁止です [1]"} =
             Gemini.generate_stream("m", "q", opts ++ [think: false], &send(test_pid, {:d, &1}))

    assert_received {:d, "USB メモリは"}
    assert_received {:d, "禁止です [1]"}
    refute_received {:d, "推論"}
  end

  test "a model that can't switch thinking off is retried without it", %{opts: opts} do
    StubGemini.set(:reject_thinking, true)
    StubGemini.set(:parts, [%{"text" => "回答"}])

    assert {:ok, "回答"} =
             Gemini.generate_stream("pro", "q", opts ++ [think: false], fn _ -> :ok end)

    assert_received {:stub_gemini, _, %{"generationConfig" => %{"thinkingConfig" => _}}}
    assert_received {:stub_gemini, _, second}
    refute Map.has_key?(second["generationConfig"] || %{}, "thinkingConfig")
  end

  test "a 429 waits for Gemini's retryDelay and then succeeds", %{opts: opts} do
    StubGemini.set(:rate_limit_once, true)
    StubGemini.set(:parts, [%{"text" => "QA"}])

    started = System.monotonic_time(:millisecond)
    assert {:ok, "QA"} = Gemini.generate("m", "q", opts)
    assert System.monotonic_time(:millisecond) - started >= 200
  end

  test "retry hints come from Retry-After or RetryInfo" do
    assert HTTP.retry_hint_ms(%{headers: %{"retry-after" => ["2"]}, body: %{}}) == 2000

    body = %{"error" => %{"details" => [%{"retryDelay" => "30s"}]}}
    assert HTTP.retry_hint_ms(%{headers: %{}, body: body}) == 30_000
    assert HTTP.retry_hint_ms(%{headers: %{}, body: "x"}) == nil
  end
end
