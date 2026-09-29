defmodule AskDriveWeb.AdminAuthSettingsTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{Accounts, FakeLdap, Settings}
  alias AskDriveWeb.UserAuth
  import AskDrive.LdapHelper

  # the POC: login off by the setting (not the environment), a guest administrator
  setup do
    {:ok, _} = Settings.set_auth_required(false)
    on_exit(&FakeLdap.reset/0)
    :ok
  end

  test "switching login on from the guest session: needs a way to sign in, registers the admin",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    assert has_element?(view, "#auth-settings", "無効（ゲスト・POC）")

    # no way to sign in yet
    view |> form("#enable-auth-form", %{"admin_email" => "boss@example.com"}) |> render_submit()
    assert render(view) =~ "ログインの方法がありません"
    assert UserAuth.auth_mode() == {:disabled, :setting}

    enable_ldap!()
    {:ok, _} = AskDrive.Accounts.AdminAccess.force_set_password("admin-pass-1")
    {:ok, view, _html} = live(build_conn(), ~p"/admin?tab=settings")

    # another domain is refused
    view |> form("#enable-auth-form", %{"admin_email" => "boss@other.com"}) |> render_submit()
    assert render(view) =~ "@example.com"

    assert {:error, {:redirect, %{to: "/login"}}} =
             view
             |> form("#enable-auth-form", %{"admin_email" => "Boss@example.com"})
             |> render_submit()

    assert UserAuth.auth_mode() == {:enabled, :setting}
    assert Accounts.get_user_by_email("boss@example.com").admin_eligible

    # now the chat needs signing in
    assert build_conn() |> get(~p"/it-support") |> redirected_to() =~ "/login"
  end

  test "an administrator switches it off again", %{conn: conn} do
    {:ok, _} = Settings.set_auth_required(true)
    admin = user_fixture(%{admin_eligible: true})
    conn = log_in_admin(conn, admin)

    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    assert has_element?(view, "#auth-settings", "有効")
    view |> element("#disable-auth-btn") |> render_click()

    assert UserAuth.auth_mode() == {:disabled, :setting}
    assert build_conn() |> get(~p"/it-support") |> html_response(200) =~ "chat-form"
  end

  test "ASK_DRIVE_DISABLE_AUTH in the environment fixes the mode (no switch on the screen)", %{
    conn: conn
  } do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
    {:ok, _} = Settings.set_auth_required(true)

    assert UserAuth.auth_mode() == {:disabled, :env}
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    assert has_element?(view, "#auth-env-fixed")
    refute has_element?(view, "#enable-auth-form")
    refute has_element?(view, "#disable-auth-btn")
  end

  describe "mix ask_drive.auth (./app.sh auth) — lockout recovery" do
    test "disable, enable with an administrator, ldap off/on, status" do
      enable_ldap!()
      {:ok, _} = Settings.set_auth_required(true)

      run = fn args ->
        ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.AskDrive.Auth.run(args) end)
      end

      assert run.(["disable"]) =~ "無効にしました"
      assert UserAuth.auth_mode() == {:disabled, :setting}

      assert run.(["enable", "boss@example.com"]) =~ "有効にしました"
      assert UserAuth.auth_mode() == {:enabled, :setting}
      assert Accounts.get_user_by_email("boss@example.com").admin_eligible

      assert run.(["ldap", "off"]) =~ "無効"
      refute Settings.platform_setting!().ldap_enabled
      assert run.(["ldap", "on"]) =~ "有効"

      out = run.(["status"])
      assert out =~ "ログイン認証: 有効（設定）"
      assert out =~ "Google Secure LDAP: 有効"
    end

    test "enable refuses without a way to sign in" do
      assert_raise Mix.Error, ~r/ログインの方法がありません/, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.AskDrive.Auth.run(["enable", "a@example.com"])
        end)
      end
    end
  end
end
