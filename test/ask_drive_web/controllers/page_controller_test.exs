defmodule AskDriveWeb.PageControllerTest do
  use AskDriveWeb.ConnCase

  describe "login required (spec F-1308)" do
    test "signed out, the portal and a chat send you to the login page, remembering the app",
         %{conn: conn} do
      assert get(conn, ~p"/") |> redirected_to() == "/login?return_to=%2F"

      conn = get(build_conn(), ~p"/it-support")
      assert redirected_to(conn) == "/login?return_to=%2Fit-support"

      # the login page keeps where to go back to (only paths on this site)
      conn = get(build_conn(), "/login?return_to=/it-support")
      assert get_session(conn, :user_return_to) == "/it-support"
      conn = get(build_conn(), "/login?return_to=//evil.example.com")
      refute get_session(conn, :user_return_to)
    end

    test "signed in, the portal lists the apps and the chat opens", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ "Select a desk to ask questions." or html =~ "相談したい窓口を選んでください"
      assert html =~ "AskDrive for IT-Support"
      assert conn |> get(~p"/it-support") |> html_response(200) =~ "chat-form"
    end

    test "an unknown app redirects to the portal", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/no-such-app")
      assert redirected_to(conn) == ~p"/"
    end

    test "the first-access setup stays reachable without signing in", %{conn: conn} do
      conn = get(conn, ~p"/setup")
      refute redirected_to(conn, 302) =~ "/login"
    end
  end

  describe "login off (the POC guest)" do
    setup do
      System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
      on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
    end

    test "the portal and the chat open without signing in", %{conn: conn} do
      assert conn |> get(~p"/") |> html_response(200) =~ "AskDrive for IT-Support"
      assert build_conn() |> get(~p"/it-support") |> html_response(200) =~ "chat-form"
    end
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
