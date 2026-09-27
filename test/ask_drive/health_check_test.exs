defmodule AskDrive.HealthCheckTest do
  use AskDrive.DataCase

  test "health check runs and checks sqlite-vec and cli" do
    results = AskDrive.HealthCheck.check()
    assert is_map(results)
    assert Map.has_key?(results, :sqlite_vec)
    assert Map.has_key?(results, :ollama)
    assert Map.has_key?(results, :pdftotext)
    assert Map.has_key?(results, :pandoc)

    # In our environment, sqlite-vec should be loaded
    assert {:ok, _version} = results.sqlite_vec
  end
end
