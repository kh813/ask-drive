defmodule AskDriveWeb.AdminAccessTest do
  @moduledoc "Entering Platform Admin: platform administrators, each confirming it is them (spec 6.9)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AskDrive.LdapHelper

  alias AskDrive.Accounts.AdminAccess

  setup do
    boss = user_fixture(email: "boss@example.com", admin_eligible: true)
    on_exit(&AskDrive.FakeLdap.reset/0)
    %{boss: boss}
  end

  defp signed_in(user, at) do
    build_conn()
    |> log_in_user(user)
    |> Plug.Conn.put_session(:authenticated_at, at)
  end

  describe "without LDAP: a recent sign-in is the proof of identity" do
    test "signed in just now: straight into Platform Admin", %{boss: boss} do
      conn = signed_in(boss, System.system_time(:second)) |> get(~p"/admin/elevate")
      assert redirected_to(conn) == ~p"/admin"

      {:ok, _view, html} = live(recycle(conn), ~p"/admin")
      assert html =~ "全体管理"
      assert [%{event: "granted"} | _] = AdminAccess.list_elevation_logs()
    end

    test "signed in long ago: asked to sign in again, which comes back here", %{boss: boss} do
      conn = signed_in(boss, System.system_time(:second) - 3600)
      html = conn |> get(~p"/admin/elevate") |> html_response(200)
      assert html =~ "reauth-btn"
      refute html =~ ~s(type="password")

      conn = get(conn, ~p"/admin/reauth")
      assert redirected_to(conn) == "/login?return_to=%2Fadmin%2Felevate"
      refute get_session(conn, :user_id)
    end
  end

  describe "with LDAP: the administrator's own password" do
    setup do
      enable_ldap!()

      AskDrive.FakeLdap.put_users(%{
        "boss@example.com" => %{
          dn: "uid=boss,ou=Users,dc=example,dc=com",
          password: "own-pass",
          name: "Boss"
        }
      })

      :ok
    end

    test "the right password lets in; a wrong one says so and counts", %{boss: boss} do
      conn = signed_in(boss, System.system_time(:second))
      assert conn |> get(~p"/admin/elevate") |> html_response(200) =~ "Google Workspace"

      bad = post(conn, ~p"/admin/elevate", %{"admin" => %{"password" => "nope"}})
      assert html_response(bad, 200) =~ "パスワードが正しくありません"
      assert [%{event: "denied"} | _] = AdminAccess.list_elevation_logs()

      good = post(conn, ~p"/admin/elevate", %{"admin" => %{"password" => "own-pass"}})
      assert redirected_to(good) == ~p"/admin"
      assert {:ok, _view, _html} = live(recycle(good), ~p"/admin")
    end
  end

  test "someone who isn't a platform administrator is turned away — a desk's administrator too" do
    owner = user_fixture(email: "owner@example.com")
    {:ok, _} = AskDrive.Accounts.add_app_admin(owner, "it-support")
    conn = signed_in(owner, System.system_time(:second))

    conn = get(conn, ~p"/admin/elevate")
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "全体管理者だけ"

    conn = post(recycle(conn), ~p"/admin/elevate", %{"admin" => %{"password" => "x"}})
    assert redirected_to(conn) == ~p"/"
  end
end
