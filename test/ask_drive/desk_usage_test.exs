defmodule AskDrive.DeskUsageTest do
  @moduledoc "The desk admin's usage figures: questions, tokens by chat and batch, speed (F-1413)."
  use AskDrive.DataCase, async: false

  alias AskDrive.Metrics
  alias AskDrive.QA.QuestionLog

  defp question!(tier, resolved? \\ false) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%QuestionLog{
      question: "q",
      tier_reached: tier,
      asked_at: now,
      resolved_at: if(resolved?, do: now)
    })
  end

  defp usage!(purpose, tokens, latency \\ 100) do
    :ok =
      Metrics.record(%{
        provider: "ollama",
        model: "m",
        purpose: purpose,
        total_tokens: tokens,
        latency_ms: latency,
        status: "ok"
      })
  end

  test "no questions yet" do
    assert %{questions: 0, solved_rate: nil, speed: :unknown} = Metrics.desk_summary()
  end

  test "questions solved, tokens split between the chat and the nightly batch" do
    question!(0)
    question!(1)
    question!(2)
    question!(3, true)

    usage!("chat_summary", 300, 5_000)
    usage!("query_embedding", 10)
    usage!("generation", 2_000)
    usage!("embedding", 500)

    summary = Metrics.desk_summary()
    assert summary.questions == 4
    assert summary.solved == 3
    assert summary.unsolved == 1
    assert summary.solved_rate == 75
    assert summary.instant_rate == 50
    assert summary.chat.tokens == 310
    assert summary.batch.tokens == 2_500
    assert summary.speed == :good
  end

  test "a slow AI summary rates the speed a little slow" do
    question!(2)
    usage!("chat_summary", 300, 60_000)
    assert Metrics.desk_summary().speed == :slow
  end
end
