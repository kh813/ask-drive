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
    assert has_element?(view, "#drive-settings-form input[name='setting[drive_folder_id]']")
    refute has_element?(view, "#settings-form input[name='setting[drive_folder_id]']")

    view
    |> form("#drive-settings-form", %{
      "setting" => %{"drive_folder_id" => "1AbCdEf", "drive_folder_name" => "マニュアル"}
    })
    |> render_submit()

    assert Settings.get_setting!().drive_folder_id == "1AbCdEf"
    assert Settings.get_setting!().drive_folder_name == "マニュアル"
  end

  test "one save button for the whole card, at its bottom", %{conn: conn} do
    for mode <- ["service_account", "oauth"] do
      {:ok, _} = Settings.update_setting(Settings.get_setting!(), %{drive_auth_mode: mode})
      {:ok, _view, html} = live(conn, "/it-support/admin?tab=settings")
      [card] = Regex.run(~r{<form[^>]*id="drive-settings-form".*?</form>}s, html)
      assert length(Regex.scan(~r/type="submit"/, card)) == 1
      # the save button comes after the folder fields
      assert :binary.match(card, "drive_folder_id") <
               :binary.match(card, "save-drive-settings-btn")
    end
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
    assert has_element?(view, "#drive-settings-form #drive-oauth-client-fields")
    assert has_element?(view, "#drive-oauth-client-missing")
    refute has_element?(view, "#drive-auth-link")

    view
    |> form("#drive-settings-form", %{
      "setting" => %{
        "drive_oauth_client_id" => "desk.apps.googleusercontent.com",
        "drive_oauth_client_secret" => "desk-secret"
      }
    })
    |> render_submit()

    assert has_element?(view, "#drive-auth-link")
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

  describe "authorizing Drive from the administrator's own browser, by pasting (F-347)" do
    setup %{conn: conn} do
      {:ok, _} =
        Settings.update_setting(Settings.get_setting!(), %{
          drive_auth_mode: "oauth",
          drive_oauth_client_id: "desk.apps.googleusercontent.com",
          drive_oauth_client_secret: "desk-secret"
        })

      {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")
      %{view: view}
    end

    defp auth_url(view) do
      view
      |> element("#drive-auth-link")
      |> render()
      |> then(&Regex.run(~r{href="([^"]+)"}, &1))
      |> List.last()
      |> String.replace("&amp;", "&")
      |> URI.parse()
      |> Map.get(:query)
      |> URI.decode_query()
    end

    test "the link asks Google to come back to localhost, offline, with PKCE and the chosen account",
         %{view: view} do
      q = auth_url(view)
      assert q["client_id"] == "desk.apps.googleusercontent.com"
      assert q["redirect_uri"] == "http://localhost"
      assert q["access_type"] == "offline"
      assert q["code_challenge_method"] == "S256"
      assert q["scope"] =~ "drive.readonly"
      refute Map.has_key?(q, "login_hint")

      view
      |> form("#drive-settings-form", %{"drive_login_hint" => "sync@example.com"})
      |> render_change()

      assert auth_url(view)["login_hint"] == "sync@example.com"
    end

    test "what's pasted is checked before asking Google", %{view: view} do
      view |> form("#drive-settings-form", %{"drive_auth_code" => ""}) |> render_change()
      view |> element("#drive-auth-finish-btn") |> render_click()
      assert render(view) =~ "認可コードが見つかりません"

      view
      |> form("#drive-settings-form", %{
        "drive_auth_code" => "http://localhost/?state=someone-else&code=abc"
      })
      |> render_change()

      view |> element("#drive-auth-finish-btn") |> render_click()
      assert render(view) =~ "別の認可のアドレスです"

      view
      |> form("#drive-settings-form", %{
        "drive_auth_code" => "http://localhost/?error=access_denied"
      })
      |> render_change()

      view |> element("#drive-auth-finish-btn") |> render_click()
      assert render(view) =~ "Google で許可されませんでした"
    end
  end

  test "the pasted address or the bare code both give the code" do
    alias AskDrive.Drive.OAuth

    assert OAuth.code_from_paste("http://localhost/?state=s1&code=4/0AbC&scope=x", "s1") ==
             {:ok, "4/0AbC"}

    assert OAuth.code_from_paste("  4/0AbC  ", "s1") == {:ok, "4/0AbC"}

    assert OAuth.code_from_paste("http://localhost/?state=s2&code=x", "s1") ==
             {:error, :state_mismatch}

    assert OAuth.code_from_paste("http://localhost/", "s1") == {:error, :no_code}
  end
end
