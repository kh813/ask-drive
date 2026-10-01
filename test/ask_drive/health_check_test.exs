defmodule AskDrive.HealthCheckTest do
  use AskDrive.DataCase

  test "health check runs and checks sqlite-vec and cli" do
    results = AskDrive.HealthCheck.check()
    assert is_map(results)
    assert Map.has_key?(results, :sqlite_vec)
    assert Map.has_key?(results, :llm_generation)
    assert Map.has_key?(results, :llm_embedding)
    assert Map.has_key?(results, :generation_provider)
    assert Map.has_key?(results, :embedding_provider)
    assert Map.has_key?(results, :pdftotext)
    assert Map.has_key?(results, :pandoc)

    # In our environment, sqlite-vec should be loaded
    assert {:ok, _version} = results.sqlite_vec
  end

  test "an API key not registered yet is reported as a step to do, not an auth failure" do
    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        llm_provider: "gemini",
        embed_provider: "gemini",
        gemini_api_key: ""
      })

    results = AskDrive.HealthCheck.check()
    assert results.generation_key_missing and results.embedding_key_missing
    assert {:error, msg} = results.llm_generation
    assert msg =~ "API キーが未設定です"
    refute msg =~ "認証に失敗"
  end
end
