defmodule AskDriveWeb.NoProviderBadgeTest do
  @moduledoc """
  Which cloud API answers is the platform's setting, not something the people asking need to
  know: the header no longer names it on every screen (it showed "External AI: Google Agent
  Platform (Vertex AI)" once Agent Platform was chosen, v0.2.3).
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Settings

  test "the header doesn't name the cloud API generating answers", %{conn: conn} do
    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{
        batch_llm_mode: "cloud",
        cloud_llm_provider: "vertex",
        cloud_llm_model: "gemini-2.5-flash"
      })

    user = user_fixture()
    {:ok, view, html} = live(log_in_user(conn, user), "/it-support")

    refute has_element?(view, "#external-llm-badge")
    refute html =~ "Agent Platform"
  end
end
