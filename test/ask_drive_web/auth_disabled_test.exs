defmodule AskDriveWeb.AuthDisabledTest do
  @moduledoc """
  `ASK_DRIVE_DISABLE_AUTH` (spec 6.9.6, POC / trusted-LAN mode) must open admin to an
  anonymous visitor, and the POC default (`:auth_disabled_by_default`, off in test.exs so
  every other test keeps the real flow) must apply when the variable is unset. Chat is open
  either way (spec 6.9.5). Runs `async: false` because it mutates process-globals: the env var
  and the application env read by `AskDriveWeb.UserAuth.auth_disabled?/0`.
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    on_exit(fn ->
      System.delete_env("ASK_DRIVE_DISABLE_AUTH")
      Application.put_env(:ask_drive, :auth_disabled_by_default, false)
    end)
  end

  test "GET /admin is open with no session when the default is on and the flag is unset", %{
    conn: conn
  } do
    Application.put_env(:ask_drive, :auth_disabled_by_default, true)
    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "全体管理"
  end

  test "ASK_DRIVE_DISABLE_AUTH=false restores login even when the default is on", %{
    conn: conn
  } do
    Application.put_env(:ask_drive, :auth_disabled_by_default, true)
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "false")
    conn = get(conn, ~p"/admin")
    assert redirected_to(conn) == ~p"/login"
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
    assert html =~ "全体管理"
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
