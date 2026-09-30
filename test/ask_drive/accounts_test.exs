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

  test "AppAdminAccess: only a platform admin resets (clears) an app's password" do
    alias AskDrive.Accounts.AppAdminAccess
    alias AskDrive.Apps

    super_admin =
      %AskDrive.Accounts.User{}
      |> AskDrive.Accounts.User.changeset(%{
        email: "super@example.com",
        name: "Super",
        admin_eligible: true,
        status: "active"
      })
      |> AskDrive.Repo.insert!()

    owner =
      %AskDrive.Accounts.User{}
      |> AskDrive.Accounts.User.changeset(%{
        email: "owner@example.com",
        name: "Owner",
        admin_eligible: false,
        status: "active"
      })
      |> AskDrive.Repo.insert!()

    app = Apps.get_by_slug!("it-support")
    {:ok, _} = AskDrive.Accounts.add_app_admin(owner, "it-support")
    :ok = AppAdminAccess.set_initial(owner, app, "owner-pass-1")

    assert {:error, :not_authorized} = AppAdminAccess.reset(owner, app)
    assert :ok = AppAdminAccess.reset(super_admin, app)
    refute AppAdminAccess.password_set?(app)
    assert AppAdminAccess.setting(app).app_admin_password_reset_by == "super@example.com"
  end
end
