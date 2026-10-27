defmodule AskDrive.LLM.QuotaKeyTest do
  @moduledoc "Which desks share a cloud API's rate limits (F-841)."
  use AskDrive.DataCase, async: false

  alias AskDrive.LLM
  alias AskDrive.Settings.Setting

  defp cloud(provider, attrs),
    do: struct(%Setting{batch_llm_mode: "cloud", cloud_llm_provider: provider}, attrs)

  test "the same provider and API key share; another key does not" do
    a = LLM.quota_key(cloud("gemini", gemini_api_key: "key-1"))
    assert a == LLM.quota_key(cloud("gemini", gemini_api_key: "key-1"))
    refute a == LLM.quota_key(cloud("gemini", gemini_api_key: "key-2"))
    refute a == LLM.quota_key(cloud("openai", openai_api_key: "key-1"))
  end

  test "the key itself is never in it" do
    {_provider, fingerprint} = LLM.quota_key(cloud("gemini", gemini_api_key: "AIza-secret"))
    refute fingerprint =~ "secret"
  end

  test "Vertex AI: the project, whichever key reaches it" do
    a = LLM.quota_key(cloud("vertex", vertex_project: "dept-a", vertex_api_key: "k1"))
    assert a == {"vertex", "dept-a"}
    assert a == LLM.quota_key(cloud("vertex", vertex_project: "dept-a", vertex_api_key: "k2"))
    refute a == LLM.quota_key(cloud("vertex", vertex_project: "dept-b", vertex_api_key: "k1"))
  end

  test "how many at once: the desk's number on a cloud API, one on a local LLM" do
    assert LLM.generation_concurrency(
             cloud("gemini", gemini_api_key: "k", cloud_generation_concurrency: 12)
           ) == 12

    assert LLM.generation_concurrency(%Setting{batch_llm_mode: "local", llm_provider: "ollama"}) ==
             1
  end
end
