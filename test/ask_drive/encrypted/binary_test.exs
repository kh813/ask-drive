defmodule AskDrive.Encrypted.BinaryTest do
  use AskDrive.DataCase
  alias AskDrive.Accounts.GoogleAccount
  alias AskDrive.Encrypted.Binary, as: EncryptedBinary

  test "encrypts and decrypts binary/string values with AES-256-GCM" do
    plaintext = "super_secret_refresh_token_12345"

    {:ok, dumped} = EncryptedBinary.dump(plaintext)
    assert is_binary(dumped)
    refute dumped == plaintext
    # IV (12) + Tag (16) + ciphertext
    assert byte_size(dumped) == 12 + 16 + byte_size(plaintext)

    {:ok, loaded} = EncryptedBinary.load(dumped)
    assert loaded == plaintext
  end

  test "stores encrypted tokens in google_accounts table" do
    raw_token = "ya29.sample_google_access_token_xyz"
    raw_refresh = "1//sample_google_refresh_token_abc"

    {:ok, account} =
      %GoogleAccount{}
      |> GoogleAccount.changeset(%{
        email: "test@example.com",
        access_token: raw_token,
        refresh_token: raw_refresh,
        status: "connected"
      })
      |> Repo.insert()

    # When querying through Ecto, decrypted automatically
    loaded_account = Repo.get!(GoogleAccount, account.id)
    assert loaded_account.access_token == raw_token
    assert loaded_account.refresh_token == raw_refresh

    # When querying raw database directly, verify it is NOT plaintext
    {:ok, %{rows: [[db_access_token, db_refresh_token]]}} =
      Repo.query("SELECT access_token, refresh_token FROM google_accounts WHERE id = ?", [
        account.id
      ])

    refute db_access_token == raw_token
    refute db_refresh_token == raw_refresh
    assert is_binary(db_access_token)
    assert is_binary(db_refresh_token)
  end
end
