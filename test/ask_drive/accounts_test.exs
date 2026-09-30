defmodule AskDrive.AccountsTest do
  use AskDrive.DataCase
  alias AskDrive.Accounts

  test "save_tokens/1 and get_account/0 manage singleton credentials" do
    assert is_nil(Accounts.get_account())

    {:ok, account} =
      Accounts.save_tokens(%{
        email: "user@example.com",
        access_token: "access_123",
        refresh_token: "refresh_456",
        expires_in: 3600,
        scope: "drive.readonly"
      })

    assert account.email == "user@example.com"
    assert account.access_token == "access_123"
    assert account.refresh_token == "refresh_456"

    # Updating tokens preserves refresh token if nil
    {:ok, updated} =
      Accounts.save_tokens(%{
        access_token: "access_new_789",
        expires_in: 3600
      })

    assert updated.access_token == "access_new_789"
    assert updated.refresh_token == "refresh_456"
  end

  test "get_valid_access_token returns current token if not expired" do
    {:ok, _account} =
      Accounts.save_tokens(%{
        email: "user@example.com",
        access_token: "valid_token_xyz",
        refresh_token: "refresh_token_xyz",
        expires_in: 3600
      })

    assert {:ok, "valid_token_xyz"} = Accounts.get_valid_access_token()
  end

  test "app admin delegation and permission check" do
    user =
      %AskDrive.Accounts.User{}
      |> AskDrive.Accounts.User.changeset(%{
        email: "staff@example.com",
        name: "Staff",
        admin_eligible: false,
        status: "active"
      })
      |> AskDrive.Repo.insert!()

    assert Accounts.app_admin_eligible?(user, "hr") == false
    assert Accounts.any_admin_eligible?(user) == false
    assert Accounts.list_user_app_slugs(user) == []

    # Assign to hr
    {:ok, _} = Accounts.add_app_admin(user, "hr")
    assert Accounts.app_admin_eligible?(user, "hr") == true
    assert Accounts.app_admin_eligible?(user, "it-support") == false
    assert Accounts.any_admin_eligible?(user) == true
    assert Accounts.list_user_app_slugs(user) == ["hr"]

    # Assign multiple apps via set_user_apps
    :ok = Accounts.set_user_apps(user, ["it-support", "finance"])
    assert Accounts.app_admin_eligible?(user, "hr") == false
    assert Accounts.app_admin_eligible?(user, "it-support") == true
    assert Accounts.app_admin_eligible?(user, "finance") == true

    # Super admin has access to all apps
    super_admin =
      %AskDrive.Accounts.User{}
      |> AskDrive.Accounts.User.changeset(%{
        email: "superadmin@example.com",
        name: "SuperAdmin",
        admin_eligible: true,
        status: "active"
      })
      |> AskDrive.Repo.insert!()

    assert Accounts.app_admin_eligible?(super_admin, "hr") == true
    assert Accounts.app_admin_eligible?(super_admin, "finance") == true
    assert Accounts.any_admin_eligible?(super_admin) == true
  end

  test "AdminAccess: access password set, verify, and disable" do
    alias AskDrive.Accounts.AdminAccess
    alias AskDrive.Settings

    setting = Settings.get_setting!()
    assert AdminAccess.verify_access_password("any_candidate", setting) == true

    # Set access password
    {:ok, updated} = AdminAccess.set_access_password(setting, "secret12345")
    assert updated.access_password_enabled == true
    assert is_binary(updated.access_password_hash)

    assert AdminAccess.verify_access_password("secret12345", updated) == true
    assert AdminAccess.verify_access_password("wrongpassword", updated) == false

    # Disable access password
    {:ok, disabled} = AdminAccess.disable_access_password(updated)
    assert disabled.access_password_enabled == false
    assert AdminAccess.verify_access_password("wrongpassword", disabled) == true
  end

  test "AppAdminAccess: app admins add others and may leave, but never the last one" do
    alias AskDrive.Accounts.AppAdminAccess
    alias AskDrive.Apps

    app = Apps.get_by_slug!("it-support")
    {:ok, owner} = AskDrive.Accounts.ensure_user("owner@example.com")
    {:ok, stranger} = AskDrive.Accounts.ensure_user("stranger@example.com")
    {:ok, _} = AskDrive.Accounts.add_app_admin(owner, "it-support")

    assert {:error, :not_authorized} = AppAdminAccess.add_admins(stranger, app, ["x@example.com"])
    assert {:error, :last_admin} = AppAdminAccess.remove_admin(owner, app, owner)

    :ok = AppAdminAccess.add_admins(owner, app, ["next@example.com"])
    successor = AskDrive.Accounts.get_user_by_email("next@example.com")
    assert AskDrive.Accounts.assigned_app_admin?(successor, "it-support")

    assert :ok = AppAdminAccess.remove_admin(owner, app, owner)
    refute AskDrive.Accounts.assigned_app_admin?(owner, "it-support")

    changes = AppAdminAccess.admin_changes(app)

    assert [
             %{event: "app_admin_removed", target: "owner@example.com"},
             %{event: "app_admin_added"} | _
           ] = changes
  end

  test "the default app gets the platform administrators while it has none (F-1116)" do
    alias AskDrive.Accounts.AppAdminAccess
    alias AskDrive.Apps

    app = Apps.primary()
    {:ok, a} = AskDrive.Accounts.grant_admin("it-a@example.com")
    {:ok, b} = AskDrive.Accounts.grant_admin("it-b@example.com")

    :ok = AppAdminAccess.ensure_primary_admins()
    assert AppAdminAccess.admins(app) |> Enum.map(& &1.email) == [a.email, b.email]
    assert [%{actor: "AskDrive（自動設定）"} | _] = AppAdminAccess.admin_changes(app)

    # once it has administrators, later platform administrators aren't added
    {:ok, _} = AskDrive.Accounts.grant_admin("it-c@example.com")
    :ok = AppAdminAccess.ensure_primary_admins()
    assert length(AppAdminAccess.admins(app)) == 2
  end
end
