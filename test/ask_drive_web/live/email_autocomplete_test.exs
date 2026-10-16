defmodule AskDriveWeb.EmailAutocompleteTest do
  @moduledoc "E-mail fields completed from the Secure LDAP directory (spec F-1115)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AskDrive.LdapHelper

  alias AskDrive.{FakeLdap, Ldap, Settings}

  setup do
    {setting, _} = enable_ldap!()

    FakeLdap.put_users(%{
      "taro@example.com" => %{
        dn: "uid=taro,ou=Users,dc=example,dc=com",
        password: "p",
        name: "山田 太郎"
      },
      "tamaki@example.com" => %{
        dn: "uid=tamaki,ou=Users,dc=example,dc=com",
        password: "p",
        name: "佐藤 環"
      },
      "hanako@example.com" => %{
        dn: "uid=hanako,ou=Users,dc=example,dc=com",
        password: "p",
        name: "山田 花子"
      }
    })

    on_exit(&FakeLdap.reset/0)
    %{setting: setting}
  end

  test "search: mail starting with, or a name containing, the text; nothing under 2 characters",
       %{setting: setting} do
    assert setting |> Ldap.search_users("ta") |> Enum.map(& &1.email) ==
             ["tamaki@example.com", "taro@example.com"]

    assert setting |> Ldap.search_users("山田") |> Enum.map(& &1.email) |> Enum.sort() ==
             ["hanako@example.com", "taro@example.com"]

    assert Ldap.search_users(setting, "t") == []
  end

  test "unknown addresses are told apart; with LDAP off nothing is checked", %{setting: setting} do
    assert Ldap.unknown_emails(setting, ["taro@example.com", "tarou@example.com"]) ==
             {:ok, ["tarou@example.com"]}

    assert Ldap.unknown_emails(%{setting | ldap_enabled: false}, ["x@example.com"]) == :skip
  end

  test "on the app's screen: suggestions while typing, picking one, and typos refused", %{conn: _} do
    owner = user_fixture(email: "owner@example.com")
    conn = build_conn() |> log_in_user(owner) |> log_in_app_admin(owner, "it-support")
    {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")

    # typing the second address of the list: suggestions for "ta"
    view
    |> element("#add-app-admins-emails")
    |> render_keyup(%{"value" => "hanako@example.com, ta"})

    assert has_element?(view, "#add-app-admins-emails-suggestions", "山田 太郎")
    assert has_element?(view, "#add-app-admins-emails-suggestions", "tamaki@example.com")

    view
    |> element("#add-app-admins-emails-suggestions button[phx-value-email='taro@example.com']")
    |> render_click()

    assert has_element?(
             view,
             ~s(#add-app-admins-emails[value="hanako@example.com, taro@example.com, "])
           )

    refute has_element?(view, "#add-app-admins-emails-suggestions")

    # a typo is refused before anyone is added
    view |> form("#add-app-admins-form", %{"emails" => "tarou@example.com"}) |> render_submit()
    assert render(view) =~ "ディレクトリ（Google Workspace）に見つかりません: tarou@example.com"
    refute AskDrive.Accounts.get_user_by_email("tarou@example.com")

    view |> form("#add-app-admins-form", %{"emails" => "taro@example.com"}) |> render_submit()

    assert AskDrive.Accounts.assigned_app_admin?(
             AskDrive.Accounts.get_user_by_email("taro@example.com"),
             "it-support"
           )

    _ = Settings.platform_setting!()
  end
end
