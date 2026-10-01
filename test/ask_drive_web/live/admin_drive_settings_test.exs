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
    assert has_element?(view, "button#drive-connect-btn")

    view
    |> form("#drive-settings-form", %{
      "setting" => %{
        "drive_oauth_client_id" => "desk.apps.googleusercontent.com",
        "drive_oauth_client_secret" => "desk-secret"
      }
    })
    |> render_submit()

    assert has_element?(view, "a#drive-connect-btn")
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

  describe "Google アカウント認証: an account and 接続 (F-347, F-348)" do
    setup %{conn: conn} do
      {:ok, _} =
        Settings.update_setting(Settings.get_setting!(), %{
          drive_auth_mode: "oauth",
          drive_oauth_client_id: "desk.apps.googleusercontent.com",
          drive_oauth_client_secret: "desk-secret"
        })

      %{conn: conn}
    end

    defp connect_href(view) do
      view
      |> element("#drive-connect-btn")
      |> render()
      |> then(&Regex.run(~r{href="([^"]+)"}, &1))
      |> List.last()
      |> String.replace("&amp;", "&")
    end

    defp query(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    test "from another PC by IP address: 接続 opens Google in a new window (localhost, PKCE, the account) and the pasted address is saved",
         %{conn: conn} do
      conn = %{conn | host: "192.168.1.10"}
      {:ok, view, html} = live(conn, "/it-support/admin?tab=settings")
      assert has_element?(view, "#drive-connect-target", "http://localhost:")
      assert html =~ "Google アカウント認証"
      assert has_element?(view, "#drive-connect-btn[target='_blank']")
      assert has_element?(view, "#drive-manual-auth")

      q = query(connect_href(view))
      assert q["client_id"] == "desk.apps.googleusercontent.com"
      assert q["redirect_uri"] =~ ~r{^http://localhost:\d+/auth/google/callback$}
      assert q["access_type"] == "offline"
      assert q["code_challenge_method"] == "S256"
      assert q["scope"] =~ "drive.readonly"

      view
      |> form("#drive-settings-form", %{"drive_login_hint" => "sync@example.com"})
      |> render_change()

      assert query(connect_href(view))["login_hint"] == "sync@example.com"

      # pasting is enough (no button); what's pasted is checked before asking Google
      view
      |> form("#drive-settings-form", %{
        "drive_auth_code" =>
          "http://localhost:4000/auth/google/callback?state=someone-else&code=abc"
      })
      |> render_change()

      assert render(view) =~ "別の認可のアドレスです"

      view
      |> form("#drive-settings-form", %{
        "drive_auth_code" => "http://localhost/?error=access_denied"
      })
      |> render_change()

      assert render(view) =~ "Google で許可されませんでした"
    end

    test "on the server itself (localhost): Google's window comes back to AskDrive, which saves it there and updates the screen (F-352)",
         %{conn: conn} do
      conn = %{conn | host: "localhost"}
      {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")

      # 接続 opens Google in a new window; the paste box is there as a fallback
      assert has_element?(view, "#drive-connect-btn[target='_blank']")
      assert has_element?(view, "#drive-manual-auth")
      q = query(connect_href(view))
      assert q["redirect_uri"] =~ ~r{^http://localhost:\d+/auth/google/callback$}

      # Google answers on AskDrive's callback, without the admin screen's session: the
      # state names the pending authorization (here: refused at Google, so no network)
      resp =
        get(build_conn(), "/auth/google/callback", %{
          "state" => q["state"],
          "error" => "access_denied"
        })

      assert resp.status == 400
      assert resp.resp_body =~ "Google で許可されませんでした"

      # used once
      refute AskDrive.Drive.PendingAuth.pending?(q["state"])

      # a success elsewhere tells the open admin screen
      Phoenix.PubSub.broadcast(
        AskDrive.PubSub,
        "drive_auth:it-support",
        {:drive_connected, "sync@example.com"}
      )

      assert render(view) =~ "sync@example.com"
    end

    test "from another PC by a host name Google accepts: Google comes back to that host (F-350)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")
      assert has_element?(view, "#drive-connect-target", "www.example.com/auth/google/callback")
      assert has_element?(view, "#drive-connect-target", "desk.apps.googleusercontent.com")
      assert has_element?(view, "#drive-manual-auth")

      q = query(connect_href(view))
      assert q["redirect_uri"] == "http://www.example.com/auth/google/callback"
      assert AskDrive.Drive.PendingAuth.pending?(q["state"])
    end

    test "without an OAuth client, 接続 opens the one-time client section and says what's needed",
         %{conn: conn} do
      {:ok, _} =
        Settings.update_setting(Settings.get_setting!(), %{drive_oauth_client_id: ""})

      {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")
      view |> element("#drive-connect-btn") |> render_click()
      assert render(view) =~ "接続するには OAuth クライアントが必要です"
      assert has_element?(view, "#drive-oauth-client[open]")
      assert has_element?(view, "#drive-oauth-client-missing")
    end
  end

  test "the pasted address or the bare code both give the code" do
    alias AskDrive.Drive.OAuth

    assert OAuth.code_from_paste(
             "http://localhost:4000/auth/google/callback?state=s1&code=4/0AbC&scope=x",
             "s1"
           ) ==
             {:ok, "4/0AbC"}

    assert OAuth.code_from_paste("  4/0AbC  ", "s1") == {:ok, "4/0AbC"}

    assert OAuth.code_from_paste("http://localhost/?state=s2&code=x", "s1") ==
             {:error, :state_mismatch}

    assert OAuth.code_from_paste("http://localhost/", "s1") == {:error, :no_code}
  end

  test "接続テスト for the OAuth client, and which redirect URIs a web client needs (F-349)", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/admin?tab=settings")
    assert has_element?(view, "#oauth-settings #test-oauth-client-btn")
    assert html =~ "http://localhost"
    assert html =~ "/auth/google/callback"

    # nothing entered yet: said without asking Google
    view |> element("#test-oauth-client-btn") |> render_click()
    assert render(view) =~ "クライアント ID とシークレットを入力して保存してください"

    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{
        drive_auth_mode: "oauth",
        drive_oauth_client_id: "desk.apps.googleusercontent.com",
        drive_oauth_client_secret: "desk-secret"
      })

    {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")
    assert has_element?(view, "#test-drive-oauth-client-btn")
    assert has_element?(view, "#drive-redirect-mismatch-help", "redirect_uri_mismatch")
  end
end
