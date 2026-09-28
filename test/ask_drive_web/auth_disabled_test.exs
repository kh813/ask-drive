defmodule AskDriveWeb.AuthDisabledTest do
  @moduledoc """
  `ASK_DRIVE_DISABLE_AUTH` (spec 6.9.6, POC / trusted-LAN mode) must open admin to an
  anonymous visitor, while leaving the default (unset) behavior — used by every other test in
  the suite — fully intact. Chat is open either way (spec 6.9.5). Runs `async: false` because it mutates a process-global: the
  `ASK_DRIVE_ADMIN_EMAILS`-style env var read by `AskDriveWeb.UserAuth.auth_disabled?/0`.
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
  end

  test "GET /admin requires login when the flag is unset", %{conn: conn} do
    conn = get(conn, ~p"/admin")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET / hides the admin login link once the flag is set", %{conn: conn} do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    {:ok, _view, html} = live(conn, ~p"/")
    refute html =~ "admin-login-link"
  end

  test "GET /admin succeeds with no session at all once the flag is set", %{conn: conn} do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "管理ダッシュボード"
  end

  test "GET /auth/google/drive is reachable with no session once the flag is set", %{
    conn: conn
  } do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    conn = get(conn, ~p"/auth/google/drive")
    refute redirected_to(conn) in [~p"/login", ~p"/admin/elevate"]
  end

  test "GET /admin still requires elevation when the flag is unset", %{conn: conn} do
    admin = user_fixture(admin_eligible: true)
    conn = conn |> log_in_user(admin) |> get(~p"/admin")
    assert redirected_to(conn) == ~p"/admin/elevate"
  end
end
