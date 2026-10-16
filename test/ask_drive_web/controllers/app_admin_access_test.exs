defmodule AskDriveWeb.AppAdminAccessTest do
  @moduledoc "An app's admin screen: its assigned administrators, each confirming it is them (F-1113, F-1114)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Accounts
  alias AskDrive.Accounts.AppAdminAccess
  import AskDrive.LdapHelper

  setup do
    {:ok, hr} = AskDrive.Apps.create(%{slug: "hr", name: "人事部窓口"})
    owner = user_fixture(email: "owner@example.com")
    {:ok, _} = Accounts.add_app_admin(owner, "hr")
    on_exit(&AskDrive.FakeLdap.reset/0)
    %{hr: hr, owner: owner}
  end

  defp signed_in(user, at) do
    build_conn()
    |> log_in_user(user)
    |> Plug.Conn.put_session(:authenticated_at, at)
  end

  describe "without LDAP: a recent sign-in is the proof of identity" do
    test "signed in just now: straight in", %{owner: owner} do
      conn = signed_in(owner, System.system_time(:second)) |> get("/hr/admin/elevate")
      assert redirected_to(conn) == "/hr/admin"

      {:ok, _view, html} = live(recycle(conn), "/hr/admin")
      assert html =~ "人事部窓口"
    end

    test "signed in long ago: asked to sign in again, which returns here", %{owner: owner} do
      conn = signed_in(owner, System.system_time(:second) - 3600)
      html = conn |> get("/hr/admin/elevate") |> html_response(200)
      assert html =~ "app-reauth-btn"

      conn = get(conn, "/hr/admin/reauth")
      assert redirected_to(conn) == "/login?return_to=%2Fhr%2Fadmin%2Felevate"
      refute get_session(conn, :user_id)
    end
  end

  describe "with LDAP: the administrator's own password" do
    setup do
      enable_ldap!()

      AskDrive.FakeLdap.put_users(%{
        "owner@example.com" => %{
          dn: "uid=owner,ou=Users,dc=example,dc=com",
          password: "own-pass",
          name: "Owner"
        }
      })

      :ok
    end

    test "the right password lets in; a wrong one says so", %{owner: owner} do
      conn = build_conn() |> log_in_user(owner)
      assert conn |> get("/hr/admin/elevate") |> html_response(200) =~ "Google Workspace"

      bad = post(conn, "/hr/admin/elevate", %{"admin" => %{"password" => "nope"}})
      assert html_response(bad, 200) =~ "パスワードが正しくありません"

      good = post(conn, "/hr/admin/elevate", %{"admin" => %{"password" => "own-pass"}})
      assert redirected_to(good) == "/hr/admin"
    end
  end

  test "a platform admin who isn't assigned can't get in" do
    boss = user_fixture(email: "boss@example.com", admin_eligible: true)

    conn =
      build_conn()
      |> log_in_admin(boss)
      |> Plug.Conn.put_session(:authenticated_at, System.system_time(:second))

    assert {:error, {:redirect, %{to: "/hr"}}} = live(conn, "/hr/admin")
    conn = get(conn, "/hr/admin/elevate")
    assert redirected_to(conn) == "/hr"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "担当者（窓口管理者）だけ"
  end

  test "elevation is per app; being removed ends access at the next request", %{
    owner: owner,
    hr: hr
  } do
    {:ok, _} = Accounts.add_app_admin(owner, "it-support")
    conn = build_conn() |> log_in_user(owner) |> log_in_app_admin(owner, "hr")

    {:ok, _view, _html} = live(conn, "/hr/admin")

    assert {:error, {:redirect, %{to: "/it-support/admin/elevate"}}} =
             live(conn, "/it-support/admin")

    colleague = user_fixture(email: "colleague@example.com")
    {:ok, _} = Accounts.add_app_admin(colleague, "hr")
    :ok = AppAdminAccess.remove_admin(colleague, hr, owner)
    assert {:error, {:redirect, %{to: "/hr"}}} = live(conn, "/hr/admin")
  end

  test "on the app's screen: add an administrator, then hand over by removing oneself", %{
    owner: owner
  } do
    conn = build_conn() |> log_in_user(owner) |> log_in_app_admin(owner, "hr")
    {:ok, view, _html} = live(conn, "/hr/admin?tab=settings")

    # the only one: no remove button
    refute has_element?(view, "#remove-app-admin-#{owner.id}")

    view
    |> form("#add-app-admins-form", %{"emails" => "successor@example.com"})
    |> render_submit()

    assert has_element?(view, "#app-admins-card", "successor@example.com")

    assert has_element?(
             view,
             "#app-admin-changes",
             "owner@example.com が successor@example.com を追加"
           )

    assert {:error, {:redirect, %{to: "/hr"}}} =
             view |> element("#remove-app-admin-#{owner.id}") |> render_click()

    refute Accounts.assigned_app_admin?(owner, "hr")
  end

  test "a platform admin's recovery change is marked on the app's screen", %{owner: owner, hr: hr} do
    boss = user_fixture(email: "boss@example.com", admin_eligible: true)
    :ok = AppAdminAccess.add_admins(boss, hr, ["rescue@example.com"])

    conn = build_conn() |> log_in_user(owner) |> log_in_app_admin(owner, "hr")
    {:ok, view, _html} = live(conn, "/hr/admin?tab=settings")

    assert has_element?(
             view,
             "#app-admin-changes",
             "boss@example.com（全体管理者） が rescue@example.com を追加"
           )
  end
end
