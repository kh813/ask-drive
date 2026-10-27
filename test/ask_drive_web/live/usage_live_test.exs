defmodule AskDriveWeb.UsageLiveTest do
  @moduledoc "The 「利用状況」 tabs (F-1415, F-1416) and the platform's all-desk API errors."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AskDrive.AppsHelper

  alias AskDrive.{Apps, Metrics, Repo}
  alias AskDrive.QA.QuestionLog
  alias AskDrive.Usage.QuestionUsage

  setup %{conn: conn} do
    admin = user_fixture(admin_eligible: true, name: "管理者")
    %{conn: log_in_admin(conn, admin), admin: admin}
  end

  defp asked!(user_id, tokens) do
    Repo.insert!(%QuestionUsage{
      user_id: user_id,
      tokens: tokens,
      asked_at: DateTime.utc_now(:second)
    })
  end

  defp log!(question) do
    Repo.insert!(%QuestionLog{
      question: question,
      tier_reached: 3,
      asked_at: DateTime.utc_now(:second)
    })
  end

  test "a desk's tab: its active users and its frequent questions", %{conn: conn, admin: admin} do
    heavy = user_fixture(name: "山田")
    asked!(heavy.id, 50)
    asked!(heavy.id, 50)
    asked!(admin.id, 900)
    log!("経費精算の締め日")
    log!("経費精算の締め日")
    log!("一度だけの相談")

    {:ok, view, _html} = live(log_in_app_admin(conn, admin), ~p"/it-support/admin?tab=usage")

    assert has_element?(view, "#usage-people tbody tr:first-child#usage-person-#{heavy.id}")
    assert has_element?(view, "#usage-frequent-1", "経費精算の締め日")
    assert has_element?(view, "#usage-frequent-1-unsolved")
    refute has_element?(view, "#usage-frequent-rows", "一度だけの相談")

    view |> element("#usage-sort-tokens") |> render_click()
    assert has_element?(view, "#usage-people tbody tr:first-child#usage-person-#{admin.id}")

    view |> element("#usage-period-7") |> render_click()
    assert has_element?(view, "#usage-period-7.shadow-sm")
  end

  test "the platform's tab adds each person up over every desk", %{conn: conn} do
    user = user_fixture(name: "佐藤")
    asked!(user.id, 10)
    hr = create_app!("hr", "人事部窓口")
    Apps.with_app(hr, fn -> asked!(user.id, 20) end)

    {:ok, view, _html} = live(conn, ~p"/admin?tab=usage")

    assert has_element?(view, "#usage-person-#{user.id}", "佐藤")
    assert has_element?(view, "#usage-desks-#{user.id}", "人事部窓口")
    refute has_element?(view, "#usage-frequent")
  end

  test "the platform's API errors are every desk's, each with its desk", %{conn: conn} do
    hr = create_app!("hr", "人事部窓口")

    Apps.with_app(hr, fn ->
      Metrics.record(%{provider: "gemini", model: "m", purpose: "chat_summary", status: "error"})
    end)

    [error] = Apps.with_app(hr, fn -> Metrics.list_recent_errors(1) end)

    {:ok, view, _html} = live(conn, ~p"/admin?tab=metrics")
    assert has_element?(view, "#api-error-hr-#{error.id}", "人事部窓口")

    view |> element("#dismiss-api-error-hr-#{error.id}") |> render_click()
    refute has_element?(view, "#api-error-hr-#{error.id}")
    assert Apps.with_app(hr, fn -> Metrics.list_recent_errors(1) end) == []
  end
end
