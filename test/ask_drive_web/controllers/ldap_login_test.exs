defmodule AskDriveWeb.LdapLoginTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{Accounts, FakeLdap}
  import AskDrive.LdapHelper

  setup do
    on_exit(&FakeLdap.reset/0)
  end

  defp sign_in(conn, email, password),
    do: post(conn, ~p"/login/ldap", %{"ldap" => %{"email" => email, "password" => password}})

  test "the login page shows the e-mail/password form only when LDAP is enabled", %{conn: conn} do
    html = conn |> get(~p"/login") |> html_response(200)
    refute html =~ "ldap-login-form"

    enable_ldap!()
    html = build_conn() |> get(~p"/login") |> html_response(200)
    assert html =~ ~s(id="ldap-login-form")
    assert html =~ "name@example.com"
    # the "OAuth not configured" notice is for when no sign-in method exists at all
    refute html =~ "OAuth が未設定です"
  end

  test "the right password signs the employee in (a user is created from the directory)", %{
    conn: conn
  } do
    enable_ldap!()
    conn = sign_in(conn, "Taro@example.com", "correct-horse")

    assert redirected_to(conn) == "/"
    user = Accounts.get_user_by_email("taro@example.com")
    assert user.name == "山田 太郎"
    assert get_session(conn, :user_id) == user.id
  end

  test "a wrong password says so with the attempts left; 5 failures lock even the right password",
       %{conn: conn} do
    enable_ldap!()

    conn = sign_in(conn, "taro@example.com", "wrong")
    assert redirected_to(conn) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "あと 4 回"
    # the e-mail is kept in the form
    assert Phoenix.Flash.get(conn.assigns.flash, :ldap_email) == "taro@example.com"

    # from different browsers: the account lock is about the account
    for _ <- 1..4, do: sign_in(browser(), "taro@example.com", "wrong")

    conn = sign_in(browser(), "taro@example.com", "correct-horse")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "まで受け付けません"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "管理者にロックの解除"
    refute get_session(conn, :user_id)
  end

  # a browser that has opened the login page, so it carries its own device cookie
  defp browser do
    conn = get(build_conn(), ~p"/login")
    cookie = conn.resp_cookies["_askdrive_device"].value
    build_conn() |> put_req_cookie("_askdrive_device", cookie)
  end

  test "the login page gives the browser a device cookie (signed, http-only)", %{conn: conn} do
    conn = get(conn, ~p"/login")
    cookie = conn.resp_cookies["_askdrive_device"]
    assert cookie.http_only
    assert cookie.max_age > 365 * 86_400
  end

  test "10 failures from one browser lock that browser for 24 hours, not a colleague's", %{
    conn: _conn
  } do
    enable_ldap!()
    attacker = browser()
    colleague = browser()

    # 10 accounts, 1 failure each: no account lock, but the environment reaches its limit
    for i <- 1..10, do: sign_in(attacker, "u#{i}@example.com", "guess")

    conn = sign_in(attacker, "taro@example.com", "correct-horse")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "まで受け付けません"

    # same address (the test conn is 127.0.0.1 for both), another browser: signs in
    conn = sign_in(colleague, "taro@example.com", "correct-horse")
    assert get_session(conn, :user_id)
  end

  test "a client without cookies is one environment by address + User-Agent", %{conn: _conn} do
    enable_ldap!()
    script = fn -> build_conn() |> put_req_header("user-agent", "curl/8.0") end
    for i <- 1..10, do: sign_in(script.(), "u#{i}@example.com", "guess")

    conn = sign_in(script.(), "taro@example.com", "correct-horse")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "まで受け付けません"

    conn =
      sign_in(
        build_conn() |> put_req_header("user-agent", "Mozilla/5.0 Chrome/131"),
        "taro@example.com",
        "correct-horse"
      )

    assert get_session(conn, :user_id)
  end

  test "another domain is refused without asking the directory", %{conn: conn} do
    enable_ldap!()
    conn = sign_in(conn, "someone@other.com", "x")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "@example.com"
    refute_received {:ldap, :open, _}
  end

  test "the directory being unreachable is explained and not counted as a failure", %{conn: conn} do
    enable_ldap!()
    FakeLdap.put_mode(:unreachable)
    conn = sign_in(conn, "taro@example.com", "correct-horse")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "LDAP サーバーで確認できませんでした"
    assert AskDrive.Accounts.LoginThrottle.remaining("taro@example.com") == 5
  end

  test "posting while LDAP is disabled signs no one in", %{conn: conn} do
    conn = sign_in(conn, "taro@example.com", "correct-horse")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "有効になっていません"
  end

  describe "admin settings card" do
    setup do
      System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
      on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
      FakeLdap.reset()
      FakeLdap.put_owner(self())
      :ok
    end

    test "checking the box fills in Google's defaults; the test runs on unsaved choices; save keeps them",
         %{conn: conn} do
      {:ok, _} =
        AskDrive.Settings.update_setting(AskDrive.Settings.platform_setting!(), %{
          "allowed_domain" => "example.com"
        })

      pem = AskDrive.CertHelper.ca_signed(["Google"])
      {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
      assert has_element?(view, "#ldap-settings", "無効")

      # switching it on fills server, port and base DN
      view |> form("#ldap-form", %{"ldap" => %{"ldap_enabled" => "true"}}) |> render_change()

      assert has_element?(
               view,
               ~s(#ldap-form input[name="ldap[ldap_host]"][value="ldap.google.com"])
             )

      assert has_element?(view, ~s(#ldap-form input[name="ldap[ldap_port]"][value="636"]))

      assert has_element?(
               view,
               ~s(#ldap-form input[name="ldap[ldap_base_dn]"][value="dc=example,dc=com"])
             )

      file_input(view, "#ldap-form", :ldap_cert, [
        %{name: "google.crt", content: pem.cert, type: "application/x-x509-ca-cert"}
      ])
      |> render_upload("google.crt")

      file_input(view, "#ldap-form", :ldap_key, [
        %{name: "google.key", content: pem.key, type: "application/octet-stream"}
      ])
      |> render_upload("google.key")

      # test before saving: uses the chosen files and the typed values
      view |> form("#ldap-form") |> render_submit(%{"op" => "test"})
      assert has_element?(view, "#ldap-test-result", "接続できました")
      assert_received {:ldap, :open, {"ldap.google.com", 636, _}}
      # nothing saved yet, and the form kept its state (the box stays checked)
      refute AskDrive.Settings.platform_setting!().ldap_enabled
      assert has_element?(view, ~s(#ldap-form input[type="checkbox"][checked]))
      assert has_element?(view, "#ldap-pending", "google.crt")

      # save without choosing the files again
      view |> form("#ldap-form") |> render_submit(%{"op" => "save"})
      assert has_element?(view, "#ldap-settings", "有効")
      assert has_element?(view, "#ldap-cert-info", "CN=Google")
      refute has_element?(view, "#ldap-pending")

      setting = AskDrive.Settings.platform_setting!()
      assert setting.ldap_enabled
      assert setting.ldap_host == "ldap.google.com"
      assert setting.ldap_client_key == pem.key
    end

    test "testing without a certificate says what is missing, and keeps the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
      view |> form("#ldap-form", %{"ldap" => %{"ldap_enabled" => "true"}}) |> render_change()
      view |> form("#ldap-form") |> render_submit(%{"op" => "test"})

      assert has_element?(view, "#ldap-test-result", "証明書")
      assert has_element?(view, ~s(#ldap-form input[type="checkbox"][checked]))
    end

    test "active locks are listed and can be lifted", %{conn: conn} do
      env = %{
        key: "device:x",
        ip: "203.0.113.5",
        user_agent: "Mozilla/5.0 (Windows NT 10.0) Chrome/131.0"
      }

      for _ <- 1..5,
          do: AskDrive.Accounts.LoginThrottle.record_failure("taro@example.com", env, "x")

      [lock] = AskDrive.Accounts.LoginThrottle.active_locks()

      {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
      assert has_element?(view, "#login-lock-#{lock.id}", "taro@example.com")
      assert has_element?(view, "#login-lock-#{lock.id}", "Chrome 131 / Windows・203.0.113.5")

      view |> element("#unlock-#{lock.id}") |> render_click()
      refute has_element?(view, "#login-lock-#{lock.id}")
      assert AskDrive.Accounts.LoginThrottle.check("taro@example.com", "device:x") == :ok
    end
  end
end
