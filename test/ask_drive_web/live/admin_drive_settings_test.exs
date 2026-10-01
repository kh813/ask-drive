defmodule AskDriveWeb.AdminDriveSettingsTest do
  @moduledoc "A desk's Google Drive sync settings: auth, folder and a dry run (spec F-345)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Settings

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
  end

  test "the folder lives in the Drive card and is saved from there", %{conn: conn} do
    {:ok, view, html} = live(conn, "/it-support/admin?tab=settings")
    assert html =~ "Google Drive 同期設定"
    refute html =~ "Google Drive 同期認証"
    assert has_element?(view, "#drive-folder-form input[name='setting[drive_folder_id]']")
    refute has_element?(view, "#settings-form input[name='setting[drive_folder_id]']")

    view
    |> form("#drive-folder-form", %{
      "setting" => %{"drive_folder_id" => "1AbCdEf", "drive_folder_name" => "マニュアル"}
    })
    |> render_submit()

    assert Settings.get_setting!().drive_folder_id == "1AbCdEf"
    assert Settings.get_setting!().drive_folder_name == "マニュアル"
  end

  test "the sync test says what's missing before it can run", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")
    view |> element("#test-drive-sync-btn") |> render_click()
    assert has_element?(view, "#drive-sync-test-result", "先に認証")
  end

  test "Drive sync by a real Google account with the desk's own OAuth client, no platform OAuth (F-346)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")

    # selectable although the platform has no OAuth client
    view |> element("#drive-auth-mode-oauth") |> render_click()
    assert Settings.get_setting!().drive_auth_mode == "oauth"
    assert has_element?(view, "#drive-oauth-client-form")
    assert has_element?(view, "#drive-oauth-client-missing")
    refute has_element?(view, "a[href^='/auth/google/drive']")

    view
    |> form("#drive-oauth-client-form", %{
      "setting" => %{
        "drive_oauth_client_id" => "desk.apps.googleusercontent.com",
        "drive_oauth_client_secret" => "desk-secret"
      }
    })
    |> render_submit()

    assert has_element?(view, "a[href^='/auth/google/drive']")
    refute has_element?(view, "#drive-oauth-client-missing")

    # the platform's Google login stays unset and off
    refute AskDrive.Drive.OAuth.client_configured?()
    refute AskDrive.Drive.OAuth.login_enabled?()

    # authorizing goes to Google with the desk's client, asking for offline Drive access
    location = conn |> get(~p"/auth/google/drive", app: "it-support") |> redirected_to()
    assert location =~ "accounts.google.com"
    assert location =~ "client_id=desk.apps.googleusercontent.com"
    assert location =~ "drive.readonly"
    assert location =~ "access_type=offline"
  end

  test "the delegation field is called アクセスユーザー", %{conn: conn} do
    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{drive_auth_mode: "service_account"})

    {:ok, _view, html} = live(conn, "/it-support/admin?tab=settings")
    assert html =~ "アクセスユーザー（ドメイン全体の委任・任意）"
    refute html =~ "なりすま"
  end
end
