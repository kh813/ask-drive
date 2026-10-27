defmodule AskDrive.MetricsAllDesksTest do
  @moduledoc "The platform's 「API利用量・ログ」 adds up every desk's API usage (F-1411)."
  use AskDrive.DataCase, async: false
  import AskDrive.AppsHelper

  alias AskDrive.{Apps, Metrics}

  defp call!(attrs) do
    :ok =
      Metrics.record(
        Map.merge(
          %{
            provider: "gemini",
            model: "gemini-2.5-flash",
            purpose: "chat_summary",
            prompt_tokens: 100,
            completion_tokens: 50,
            request_bytes: 10,
            status: "ok"
          },
          attrs
        )
      )
  end

  test "adds up the calls, tokens and errors of every desk; the latency weighted by calls" do
    primary = Enum.find(Apps.list(), & &1.primary)
    hr = create_app!("hr", "HR")

    Apps.with_app(primary, fn ->
      call!(%{latency_ms: 100})
      call!(%{latency_ms: 300, status: "error", error_message: "boom"})
      call!(%{latency_ms: 200})
    end)

    Apps.with_app(hr, fn ->
      call!(%{latency_ms: 500, purpose: "batch_generation"})

      call!(%{
        latency_ms: 500,
        provider: "ollama",
        model: "bge-m3",
        purpose: "embedding",
        prompt_tokens: 20,
        completion_tokens: 0
      })
    end)

    summary = Metrics.all_desks_summary(30)

    assert summary.total_requests == 5
    assert summary.error_requests == 1
    assert summary.success_rate == 80.0
    assert summary.prompt_tokens == 420
    assert summary.completion_tokens == 200
    assert summary.total_tokens == 620
    assert summary.total_bytes == 50
    # (200 × 3 + 500 × 2) / 5, not the desks' averages averaged (350)
    assert summary.avg_latency_ms == 320

    # the same provider and model on two desks is one row
    assert [
             %{provider: "gemini", model: "gemini-2.5-flash", requests: 4, errors: 1} = gemini,
             %{provider: "ollama", model: "bge-m3", requests: 1, errors: 0}
           ] = summary.provider_breakdown

    assert gemini.total_tokens == 600

    assert %{requests: 3, total_tokens: 450} =
             Enum.find(summary.purpose_breakdown, &(&1.purpose == "chat_summary"))

    assert %{requests: 1} =
             Enum.find(summary.purpose_breakdown, &(&1.purpose == "batch_generation"))
  end

  test "with no calls anywhere: zeros, not a division by zero" do
    create_app!("hr", "HR")

    assert %{total_requests: 0, success_rate: 100.0, avg_latency_ms: 0, provider_breakdown: []} =
             Metrics.all_desks_summary(30)
  end
end
