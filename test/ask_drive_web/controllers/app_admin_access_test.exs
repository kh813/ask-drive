defmodule AskDriveWeb.AppAdminAccessTest do
  @moduledoc "An app's admin screen with the app's own password (spec F-1113)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Accounts
  alias AskDrive.Accounts.AppAdminAccess

  setup do
    {:ok, hr} = AskDrive.Apps.create(%{slug: "hr", name: "人事部窓口"})

    # app databases aren't rolled back between tests: start without a password
    AskDrive.Apps.with_app(hr, fn ->
      AskDrive.Settings.get_setting!()
      |> Ecto.Changeset.change(
        app_admin_password_hash: nil,
        app_admin_password_reset_at: nil,
        app_admin_password_reset_by: nil
      )
      |> AskDrive.Repo.update!()
    end)

    owner = user_fixture(email: "owner@example.com")
    {:ok, _} = Accounts.add_app_admin(owner, "hr")
    %{hr: hr, owner: owner}
  end

  defp elevate(conn, password),
    do: post(conn, "/hr/admin/elevate", %{"admin" => %{"password" => password}})

  test "no password yet: the assigned admin sets it and is let in", %{owner: owner, hr: hr} do
    conn = build_conn() |> log_in_user(owner)

    # the admin screen sends to the prompt, which asks for a new password
    assert {:error, {:redirect, %{to: "/hr/admin/elevate"}}} = live(conn, "/hr/admin")
    html = conn |> get("/hr/admin/elevate") |> html_response(200)
    assert html =~ "app-set-password-form"

    bad =
      post(conn, "/hr/admin/password", %{
        "admin" => %{"password" => "hr-pass-123", "confirmation" => "x"}
      })

    assert html_response(bad, 200) =~ "一致しません"

    conn =
      post(conn, "/hr/admin/password", %{
        "admin" => %{"password" => "hr-pass-123", "confirmation" => "hr-pass-123"}
      })

    assert redirected_to(conn) == "/hr/admin"
    assert AppAdminAccess.password_set?(hr)

    {:ok, _view, html} = live(recycle(conn), "/hr/admin")
    assert html =~ "人事部窓口"
  end

  test "wrong passwords count down and lock; the right one lets in", %{owner: owner, hr: hr} do
    :ok = AppAdminAccess.set_initial(owner, hr, "hr-pass-123")
    conn = build_conn() |> log_in_user(owner)

    assert html_response(elevate(conn, "nope"), 200) =~ "あと 4 回"
    for _ <- 1..4, do: elevate(conn, "nope")
    assert html_response(elevate(conn, "hr-pass-123"), 200) =~ "まで受け付けません"
  end

  test "a platform admin who isn't assigned can't get in, even with the platform password", %{
    owner: owner,
    hr: hr
  } do
    :ok = AppAdminAccess.set_initial(owner, hr, "hr-pass-123")
    {:ok, _} = Accounts.AdminAccess.force_set_password("platform-pass-1")
    boss = user_fixture(email: "boss@example.com", admin_eligible: true)
    conn = build_conn() |> log_in_admin(boss)

    assert {:error, {:redirect, %{to: "/hr"}}} = live(conn, "/hr/admin")
    conn = get(conn, "/hr/admin/elevate")
    assert redirected_to(conn) == "/hr"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "担当者（窓口管理者）だけ"
  end

  test "a reset ends the sessions and asks the next admin for a new password, saying who reset it",
       %{owner: owner, hr: hr} do
    conn = build_conn() |> log_in_user(owner) |> log_in_app_admin(owner, "hr", "hr-pass-123")
    {:ok, _view, _html} = live(conn, "/hr/admin")

    boss = user_fixture(email: "boss@example.com", admin_eligible: true)
    :ok = AppAdminAccess.reset(boss, hr)

    assert {:error, {:redirect, %{to: "/hr/admin/elevate"}}} = live(conn, "/hr/admin")
    html = conn |> get("/hr/admin/elevate") |> html_response(200)
    assert html =~ "boss@example.com"
    assert html =~ "app-set-password-form"
  end

  test "elevation is per app, and a password change ends the older sessions", %{
    owner: owner,
    hr: hr
  } do
    {:ok, _} = Accounts.add_app_admin(owner, "it-support")
    conn = build_conn() |> log_in_user(owner) |> log_in_app_admin(owner, "hr", "hr-pass-123")

    {:ok, _view, _html} = live(conn, "/hr/admin")
    # assigned to IT-Support too, but not elevated there
    assert {:error, {:redirect, %{to: "/it-support/admin/elevate"}}} =
             live(conn, "/it-support/admin")

    :ok = AppAdminAccess.change(owner, hr, "hr-pass-123", "hr-pass-456")
    assert {:error, {:redirect, %{to: "/hr/admin/elevate"}}} = live(conn, "/hr/admin")
  end

  test "an unassigned user is refused before any prompt" do
    stranger = user_fixture(email: "stranger@example.com")
    conn = build_conn() |> log_in_user(stranger) |> get("/hr/admin/elevate")
    assert redirected_to(conn) == "/hr"
  end
end
