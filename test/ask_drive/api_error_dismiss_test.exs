defmodule AskDrive.ApiErrorDismissTest do
  @moduledoc "The dashboard's API error list: the last week, without dismissed ones; old logs pruned (F-1411)."
  use AskDrive.DataCase, async: false

  alias AskDrive.Metrics
  alias AskDrive.Metrics.ApiUsageLog

  defp log!(status, days_ago) do
    at =
      DateTime.utc_now()
      |> DateTime.add(-days_ago * 86_400, :second)
      |> DateTime.truncate(:second)

    Repo.insert!(%ApiUsageLog{
      provider: "gemini",
      model: "m",
      purpose: "chat",
      status: status,
      error_message: if(status == "error", do: "429"),
      inserted_at: at
    })
  end

  test "only errors from the last 7 days are listed" do
    recent = log!("error", 1)
    _old = log!("error", 8)
    _ok = log!("ok", 0)

    assert Enum.map(Metrics.list_recent_errors(), & &1.id) == [recent.id]
  end

  test "a dismissed error leaves the list but the log is kept" do
    a = log!("error", 0)
    b = log!("error", 1)

    assert Metrics.dismiss_error(a.id) == 1
    assert Enum.map(Metrics.list_recent_errors(), & &1.id) == [b.id]
    assert Repo.get(ApiUsageLog, a.id).dismissed_at

    assert Metrics.dismiss_all_errors() == 1
    assert Metrics.list_recent_errors() == []
    assert Repo.aggregate(ApiUsageLog, :count) == 2

    # a new error is listed again
    c = log!("error", 0)
    assert Enum.map(Metrics.list_recent_errors(), & &1.id) == [c.id]
  end

  test "logs older than 90 days are deleted" do
    _old = log!("ok", 91)
    _old_error = log!("error", 100)
    kept = log!("ok", 89)

    assert Metrics.prune_old_logs() == 2
    assert Enum.map(Repo.all(ApiUsageLog), & &1.id) == [kept.id]
  end
end
