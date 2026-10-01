defmodule AskDriveWeb.HeaderNavTest do
  @moduledoc "Where a desk's admin screen and Platform Admin are reached from (spec F-1117)."
  use AskDriveWeb.ConnCase, async: false

  alias AskDrive.Accounts

  # the header's right-hand side, in order, as element ids
  defp right_side_ids(html) do
    ~r/id="(elevate-link|admin-mode-group|admin-mode-badge|release-admin-link|platform-admin-nav-link|locale-switcher)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  test "Platform Admin sits right before the language switch, before and after elevating", %{
    conn: conn
  } do
    admin = user_fixture(admin_eligible: true)

    # before: "Platform Admin" leads to the password prompt
    html = conn |> log_in_user(admin) |> get(~p"/") |> html_response(200)
    assert html =~ ~s(href="/admin/elevate")
    assert right_side_ids(html) == ["elevate-link", "locale-switcher"]
    refute html =~ "Act as administrator"

    # after: the same place, now the last item of the admin-mode group
    html = conn |> log_in_admin(admin) |> get(~p"/") |> html_response(200)

    assert right_side_ids(html) == [
             "admin-mode-group",
             "admin-mode-badge",
             "release-admin-link",
             "platform-admin-nav-link",
             "locale-switcher"
           ]

    # "Admin mode" with the time left on a line of its own
    assert html =~
             ~r{<span>Admin mode</span>\s*<span[^>]*id="admin-mode-remaining"[^>]*>\(\d+ min remaining\)</span>}
  end

  test "a desk's administrator gets their desk's admin link, not Platform Admin", %{conn: conn} do
    owner = user_fixture()
    {:ok, _} = Accounts.add_app_admin(owner, "it-support")

    html = conn |> log_in_user(owner) |> get(~p"/it-support") |> html_response(200)
    assert html =~ ~s(id="admin-nav-link")
    assert html =~ "Manage IT-Support"

    # the chat stands out (grey); the desk's admin link stays plain
    [chat] = Regex.run(~r/<a[^>]*id="chat-nav-link"[^>]*>/, html)
    [admin] = Regex.run(~r/<a[^>]*id="admin-nav-link"[^>]*>/, html)
    assert chat =~ "bg-zinc-100"
    refute admin =~ ~r/(?<!hover:)bg-zinc-100/
    refute html =~ ~s(id="elevate-link")
    refute html =~ ~s(id="platform-admin-nav-link")
  end
end
