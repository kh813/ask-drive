defmodule AskDriveWeb.LdapDirectoryPanelTest do
  @moduledoc "The LDAP card says how many directory users are kept and when (spec F-1313)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AskDrive.LdapHelper

  alias AskDrive.FakeLdap
  alias AskDrive.Ldap.Directory

  setup %{conn: conn} do
    enable_ldap!()
    on_exit(&FakeLdap.reset/0)
    admin = user_fixture(admin_eligible: true)
    %{conn: log_in_admin(conn, admin)}
  end

  test "not fetched yet, then the count and time once a fetch has ended", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    assert has_element?(view, "#ldap-directory-status", "未取得")
    assert has_element?(view, "#refresh-ldap-directory-btn")

    # the fetch (here run in the test, as the clock or the button would) is broadcast
    {:ok, 1} = Directory.fetch()
    assert render(view) =~ "1 人"
    refute has_element?(view, "#ldap-directory-error")
  end
end
