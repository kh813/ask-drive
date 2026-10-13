defmodule AskDriveWeb.AdminAnswerStyleTest do
  @moduledoc "The chat summary's answer style, picked in a desk's AI settings (spec F-432)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Settings

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
  end

  test "the style is chosen from a select and saved with the settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")

    assert has_element?(view, "#settings-form select[name='setting[chat_answer_style]']")
    assert has_element?(view, "#settings-form option[value='conversational']")
    assert has_element?(view, "#chat-answer-styles li", "簡潔")

    view
    |> form("#settings-form", %{"setting" => %{"chat_answer_style" => "conversational"}})
    |> render_submit()

    assert Settings.get_setting!().chat_answer_style == "conversational"
  end
end
