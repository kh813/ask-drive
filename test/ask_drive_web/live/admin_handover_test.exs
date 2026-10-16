defmodule AskDriveWeb.AdminHandoverTest do
  @moduledoc "Handing over platform administration after the initial setup (spec F-921)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Accounts

  setup do
    initial = user_fixture(email: "initial@example.com", admin_eligible: true)
    %{initial: initial}
  end

  test "the only administrator can't give up their rights; with a second one they can", %{
    conn: conn,
    initial: initial
  } do
    assert {:error, :last_admin} = Accounts.set_admin_eligible(initial, initial, false)

    conn = log_in_admin(conn, initial)
    {:ok, view, _html} = live(conn, ~p"/admin?tab=users")
    refute has_element?(view, "#give-up-admin-#{initial.id}")

    operator = user_fixture(email: "operator@example.com", admin_eligible: true)
    {:ok, view, _html} = live(conn, ~p"/admin?tab=users")
    assert has_element?(view, "#give-up-admin-#{initial.id}")

    assert {:error, {:redirect, %{to: "/"}}} =
             view |> element("#give-up-admin-#{initial.id}") |> render_click()

    refute Accounts.get_user(initial.id).admin_eligible
    assert Accounts.get_user(operator.id).admin_eligible

    # no longer let into the platform screen
    assert {:error, {:redirect, _}} = live(conn, ~p"/admin")
  end

  test "the new operator can revoke the initial administrator too", %{initial: initial} do
    operator = user_fixture(email: "operator@example.com", admin_eligible: true)
    assert {:ok, user} = Accounts.set_admin_eligible(operator, initial, false)
    refute user.admin_eligible
  end

  test "an address fixed by ASK_DRIVE_ADMIN_EMAILS can't be revoked on the screen", %{
    initial: initial
  } do
    System.put_env("ASK_DRIVE_ADMIN_EMAILS", "initial@example.com")
    on_exit(fn -> System.delete_env("ASK_DRIVE_ADMIN_EMAILS") end)

    operator = user_fixture(email: "operator@example.com", admin_eligible: true)
    assert {:error, :fixed_by_env} = Accounts.set_admin_eligible(operator, initial, false)
    assert {:error, :fixed_by_env} = Accounts.set_admin_eligible(initial, initial, false)
    assert Accounts.admin_fixed_by_env?(initial)
  end
end
