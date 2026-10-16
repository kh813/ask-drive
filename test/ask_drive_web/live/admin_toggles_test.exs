defmodule AskDriveWeb.AdminTogglesTest do
  @moduledoc "On/off switches apply at once, separately from saving values (spec F-206)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{Apps, Settings}

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
  end

  defp desk_setting, do: Apps.with_app(Apps.get_by_slug!("it-support"), &Settings.get_setting!/0)

  test "a desk's switches apply at once; 「設定を保存」 leaves them as they are", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")
    refute desk_setting().maintenance_mode

    view |> element("#toggle-maintenance") |> render_click()
    assert desk_setting().maintenance_mode
    assert has_element?(view, "#toggle-maintenance[aria-checked=true]")

    # saving the other settings doesn't switch it back off
    view |> form("#settings-form") |> render_submit()
    assert desk_setting().maintenance_mode

    view |> element("#toggle-maintenance") |> render_click()
    refute desk_setting().maintenance_mode

    before = desk_setting().chat_summary_enabled
    view |> element("#toggle-chat-summary") |> render_click()
    assert desk_setting().chat_summary_enabled == not before
  end
end
