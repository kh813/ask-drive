defmodule AskDriveWeb.PageControllerTest do
  use AskDriveWeb.ConnCase

  test "GET / is the portal listing the apps, without signing in", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "相談したい窓口を選んでください"
    assert html =~ "AskDrive for IT-Support"
  end

  test "GET /it-support renders that app's chat without signing in", %{conn: conn} do
    conn = get(conn, ~p"/it-support")
    assert html_response(conn, 200) =~ "chat-form"
  end

  test "an unknown app redirects to the portal", %{conn: conn} do
    conn = get(conn, "/no-such-app")
    assert redirected_to(conn) == ~p"/"
  end

  test "GET /admin still requires login when signed out", %{conn: conn} do
    conn = get(conn, ~p"/admin")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /it-support/admin still requires login when signed out", %{conn: conn} do
    conn = get(conn, ~p"/it-support/admin")
    assert redirected_to(conn) == ~p"/login"
  end
end
