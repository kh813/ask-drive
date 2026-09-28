defmodule AskDriveWeb.PageControllerTest do
  use AskDriveWeb.ConnCase

  test "GET / redirects to login when signed out", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET / renders the chat page when signed in", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert html_response(conn, 200) =~ "AskDrive"
  end
end
