defmodule AskDriveWeb.ChatLiveTest do
  use AskDriveWeb.ConnCase
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture())}
  end

  test "renders chat page and submits question", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "AskDrive"
    assert html =~ "chat-form"

    # Submit question
    html =
      view
      |> form("#chat-form", %{"question" => "社内規定について教えてください"})
      |> render_submit()

    assert html =~ "社内規定について教えてください"
  end

  test "answers asynchronously: question first, then the answer bubble", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"})
    |> render_submit()

    html = render_async(view, 20_000)
    assert html =~ "USBメモリの利用ルールは？"
    assert html =~ "未回答"
    refute has_element?(view, "#answer-loading")
  end

  test "resets chat history", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#chat-form", %{"question" => "質問1"})
    |> render_submit()

    assert render(view) =~ "質問1"

    view
    |> element("#reset-chat-btn")
    |> render_click()

    refute render(view) =~ "質問1"
  end

  test "signed-out visitors can chat and see the admin login link" do
    {:ok, view, _html} = live(build_conn(), ~p"/")
    assert has_element?(view, "#chat-form")
    assert has_element?(view, "#admin-login-link")
    refute has_element?(view, "#logout-link")

    view
    |> form("#chat-form", %{"question" => "ゲストの質問"})
    |> render_submit()

    assert render(view) =~ "ゲストの質問"
  end
end
