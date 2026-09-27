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
end
