defmodule AskDriveWeb.OAuthToggleTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Settings
  import AskDrive.LdapHelper

  setup do
    {:ok, _} =
      Settings.update_setting(Settings.platform_setting!(), %{
        "google_client_id" => "cid.apps.googleusercontent.com",
        "oauth_login_enabled" => "true"
      })

    on_exit(&AskDrive.FakeLdap.reset/0)
    :ok
  end

  test "switched off, the login page has no Google button and /auth/google refuses; LDAP stays",
       %{conn: conn} do
    enable_ldap!()
    assert conn |> get(~p"/login") |> html_response(200) =~ "google-login-btn"

    {:ok, _} =
      Settings.update_setting(Settings.platform_setting!(), %{"oauth_login_enabled" => "false"})

    html = build_conn() |> get(~p"/login") |> html_response(200)
    refute html =~ "google-login-btn"
    assert html =~ "ldap-login-form"

    conn = get(build_conn(), ~p"/auth/google")
    assert redirected_to(conn) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Google ログインは無効"

    # the intro speaks of the LDAP password only, not of Google accounts
    assert html =~ "Please sign in with your email address" or
             html =~ "メールアドレスと Google Workspace のパスワードでログインしてください"

    refute html =~ "Please sign in with your Google account"
    refute html =~ "Google アカウントでログインしてください"
    refute html =~ "login-divider"

    # the credentials are kept
    assert Settings.platform_setting!().google_client_id == "cid.apps.googleusercontent.com"
  end

  test "the admin screen switches Google login off and on (under 組織 → ログインの方法)", %{
    conn: conn
  } do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)

    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    assert has_element?(view, "#org-settings #oauth-settings", "有効")
    assert has_element?(view, "#org-settings #ldap-settings")

    view
    |> form("#oauth-form", %{"setting" => %{"oauth_login_enabled" => "false"}})
    |> render_submit()

    refute Settings.platform_setting!().oauth_login_enabled
    assert has_element?(view, "#oauth-settings", "無効")

    view
    |> form("#oauth-form", %{"setting" => %{"oauth_login_enabled" => "true"}})
    |> render_submit()

    assert Settings.platform_setting!().oauth_login_enabled
  end

  test "./app.sh auth oauth off|on" do
    run = &ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.AskDrive.Auth.run(&1) end)
    assert run.(["oauth", "off"]) =~ "無効にしました"
    refute Settings.platform_setting!().oauth_login_enabled
    assert run.(["status"]) =~ "Google ログイン（OAuth）: 無効（認証情報は設定済み）"
    assert run.(["oauth", "on"]) =~ "有効にしました"
    assert Settings.platform_setting!().oauth_login_enabled
  end

  test "both off by default: configured credentials alone don't put Google on the login page" do
    {:ok, _} =
      Settings.update_setting(Settings.platform_setting!(), %{"oauth_login_enabled" => "false"})

    fresh = %AskDrive.Settings.Setting{}
    refute fresh.oauth_login_enabled
    refute fresh.ldap_enabled

    html = build_conn() |> get(~p"/login") |> html_response(200)
    refute html =~ ~s(id="google-login-btn")
    refute html =~ ~s(id="ldap-login-form")
  end

  test "only Google login on: the intro speaks of Google accounts, no LDAP form", %{conn: conn} do
    html = conn |> get(~p"/login") |> html_response(200)
    assert html =~ "google-login-btn"
    assert html =~ "Please sign in with your Google account" or html =~ "Google アカウントでログインしてください"
    refute html =~ "ldap-login-form"
  end

  test "no method switched on: no buttons, and a notice saying so", %{conn: conn} do
    {:ok, _} =
      Settings.update_setting(Settings.platform_setting!(), %{"oauth_login_enabled" => "false"})

    html = conn |> get(~p"/login") |> html_response(200)
    refute html =~ "google-login-btn"
    refute html =~ "ldap-login-form"
    assert html =~ "no-login-method"
    assert html =~ "No login method configured" or html =~ "ログインの方法が設定されていません"
    refute html =~ "OAuth が未設定です"
  end
end
