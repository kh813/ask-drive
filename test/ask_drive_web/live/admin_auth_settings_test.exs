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

    # the administrators must exist in the directory (F-1115)
    FakeLdap.put_users(
      Map.new(~w(boss second third), fn name ->
        {"#{name}@example.com", %{dn: "uid=#{name},dc=example,dc=com", password: "p", name: name}}
      end)
    )

    {:ok, view, _html} = live(build_conn(), ~p"/admin?tab=settings")

    view |> form("#enable-auth-form", %{"admin_email" => "bos@example.com"}) |> render_submit()
    assert render(view) =~ "ディレクトリ（Google Workspace）に見つかりません: bos@example.com"

    # another domain is refused
    view |> form("#enable-auth-form", %{"admin_email" => "boss@other.com"}) |> render_submit()
    assert render(view) =~ "@example.com"

    # several administrators at once (commas / spaces)
    assert {:error, {:redirect, %{to: "/login"}}} =
             view
             |> form("#enable-auth-form", %{
               "admin_email" => "Boss@example.com, second@example.com  third@example.com"
             })
             |> render_submit()

    assert UserAuth.auth_mode() == {:enabled, :setting}

    for email <- ~w(boss@example.com second@example.com third@example.com),
        do: assert(Accounts.get_user_by_email(email).admin_eligible)

    # now the chat needs signing in
    assert build_conn() |> get(~p"/it-support") |> redirected_to() =~ "/login"
  end

  test "administrators are added by e-mail on the users tab, before their first sign-in", %{
    conn: conn
  } do
    {:ok, _} =
      Settings.update_setting(Settings.platform_setting!(), %{"allowed_domain" => "example.com"})

    {:ok, view, _html} = live(conn, ~p"/admin?tab=users")

    view
    |> form("#grant-admin-form", %{"emails" => "a@example.com, x@other.com"})
    |> render_submit()

    assert render(view) =~ "@example.com 以外のアドレスは指定できません: x@other.com"
    refute Accounts.get_user_by_email("a@example.com")

    view
    |> form("#grant-admin-form", %{"emails" => "a@example.com, b@example.com"})
    |> render_submit()

    assert render(view) =~ "a@example.com、b@example.com を昇格可にしました"
    assert Accounts.get_user_by_email("a@example.com").admin_eligible
    assert Accounts.get_user_by_email("b@example.com").admin_eligible
    # listed now, before they have ever signed in
    assert render(view) =~ "b@example.com"
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

      assert run.(["enable", "boss@example.com", "second@example.com"]) =~ "有効にしました"
      assert UserAuth.auth_mode() == {:enabled, :setting}
      assert Accounts.get_user_by_email("boss@example.com").admin_eligible
      assert Accounts.get_user_by_email("second@example.com").admin_eligible

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
