defmodule AskDriveWeb.ApiErrorDismissLiveTest do
  @moduledoc "Dismiss buttons on the desk's API error list (F-1411)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Metrics

  setup %{conn: conn} do
    admin = user_fixture(admin_eligible: true)
    %{conn: conn |> log_in_admin(admin) |> log_in_app_admin(admin)}
  end

  defp error! do
    :ok =
      Metrics.record(%{
        provider: "gemini",
        model: "m",
        purpose: "chat",
        status: "error",
        error_message: "429"
      })

    hd(Metrics.list_recent_errors(1))
  end

  test "one error, then all of them, are marked as seen", %{conn: conn} do
    first = error!()
    second = error!()

    {:ok, view, _html} = live(conn, ~p"/it-support/admin?tab=metrics")
    assert has_element?(view, "#api-error-#{first.id}")
    assert has_element?(view, "#api-error-#{second.id}")

    view |> element("#dismiss-api-error-#{first.id}") |> render_click()
    refute has_element?(view, "#api-error-#{first.id}")
    assert has_element?(view, "#api-error-#{second.id}")

    view |> element("#dismiss-all-api-errors-btn") |> render_click()
    refute has_element?(view, "#api-error-#{second.id}")
    refute has_element?(view, "#dismiss-all-api-errors-btn")
  end
end
