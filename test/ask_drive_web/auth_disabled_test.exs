defmodule AskDriveWeb.AuthDisabledTest do
  @moduledoc """
  `ASK_DRIVE_DISABLE_AUTH` (spec: POC / trusted-LAN mode) must open both chat and admin to an
  anonymous visitor, while leaving the default (unset) behavior — used by every other test in
  the suite — fully intact. Runs `async: false` because it mutates a process-global: the
  `ASK_DRIVE_ADMIN_EMAILS`-style env var read by `AskDriveWeb.UserAuth.auth_disabled?/0`.
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
  end

  test "GET / requires login when the flag is unset (default, matches every other test)", %{
    conn: conn
  } do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET / succeeds with no session at all once the flag is set", %{conn: conn} do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "AskDrive"
  end

  test "GET /admin succeeds with no session at all once the flag is set", %{conn: conn} do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "管理ダッシュボード"
  end

  test "GET /admin still requires elevation when the flag is unset", %{conn: conn} do
    admin = user_fixture(admin_eligible: true)
    conn = conn |> log_in_user(admin) |> get(~p"/admin")
    assert redirected_to(conn) == ~p"/admin/elevate"
  end
end
