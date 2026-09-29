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

    for _ <- 1..4, do: sign_in(build_conn(), "taro@example.com", "wrong")

    conn = sign_in(build_conn(), "taro@example.com", "correct-horse")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "まで受け付けません"
    refute get_session(conn, :user_id)
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

    test "upload the certificate and key, enable, save, and test the connection", %{conn: conn} do
      {:ok, _} =
        AskDrive.Settings.update_setting(AskDrive.Settings.platform_setting!(), %{
          "allowed_domain" => "example.com"
        })

      pem = AskDrive.CertHelper.ca_signed(["Google"])
      {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")

      assert has_element?(view, "#ldap-settings", "無効")
      assert has_element?(view, "#ldap-settings", "dc=example,dc=com")

      file_input(view, "#ldap-form", :ldap_cert, [
        %{name: "google.crt", content: pem.cert, type: "application/x-x509-ca-cert"}
      ])
      |> render_upload("google.crt")

      file_input(view, "#ldap-form", :ldap_key, [
        %{name: "google.key", content: pem.key, type: "application/octet-stream"}
      ])
      |> render_upload("google.key")

      view
      |> form("#ldap-form", %{"ldap" => %{"ldap_enabled" => "true"}})
      |> render_submit()

      assert has_element?(view, "#ldap-settings", "有効")
      assert has_element?(view, "#ldap-cert-info", "CN=Google")

      view |> element("#test-ldap-btn") |> render_click()
      assert has_element?(view, "#ldap-test-result", "接続できました")
    end
  end
end
