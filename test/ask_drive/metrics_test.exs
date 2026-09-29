defmodule AskDrive.MetricsTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Metrics

  describe "api usage logging and metrics" do
    test "record/1 creates usage log and aggregates summary" do
      :ok =
        Metrics.record(%{
          provider: "gemini",
          model: "gemini-2.5-flash",
          purpose: "chat_summary",
          prompt_tokens: 120,
          completion_tokens: 45,
          total_tokens: 165,
          request_bytes: 500,
          latency_ms: 350,
          status: "ok"
        })

      :ok =
        Metrics.record(%{
          provider: "anthropic",
          model: "claude-3-5-sonnet",
          purpose: "batch_generation",
          prompt_tokens: 300,
          completion_tokens: 100,
          total_tokens: 400,
          request_bytes: 1200,
          latency_ms: 850,
          status: "ok"
        })

      :ok =
        Metrics.record(%{
          provider: "openai",
          model: "text-embedding-3-small",
          purpose: "embedding",
          prompt_tokens: 80,
          completion_tokens: 0,
          total_tokens: 80,
          request_bytes: 240,
          latency_ms: 120,
          status: "error",
          error_message: "Rate limit exceeded (429)"
        })

      # Wait briefly for async task insertion
      Process.sleep(100)

      summary = Metrics.get_summary(30)
      assert summary.total_requests == 3
      assert summary.error_requests == 1
      assert summary.prompt_tokens == 500
      assert summary.completion_tokens == 145
      assert summary.total_tokens == 645
      assert summary.total_bytes == 1940
      assert summary.success_rate == 66.7

      errors = Metrics.list_recent_errors(10)
      assert length(errors) == 1
      assert hd(errors).provider == "openai"
      assert hd(errors).error_message =~ "429"
    end
  end
end
