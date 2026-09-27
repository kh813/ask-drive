defmodule AskDrive.Accounts do
  @moduledoc """
  Context for managing the singleton Google Account authentication and token lifecycle.
  """
  import Ecto.Query, warn: false
  alias AskDrive.Repo
  alias AskDrive.Accounts.GoogleAccount
  alias AskDrive.Drive.OAuth

  @doc """
  Gets the connected Google account (singleton), or nil if not connected.
  """
  def get_account do
    Repo.one(from a in GoogleAccount, limit: 1)
  end

  @doc """
  Saves or updates the singleton Google account tokens.
  """
  def save_tokens(attrs) do
    expires_in = attrs[:expires_in] || attrs["expires_in"] || 3600
    expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

    params = %{
      email: attrs[:email] || attrs["email"],
      access_token: attrs[:access_token] || attrs["access_token"],
      refresh_token: attrs[:refresh_token] || attrs["refresh_token"],
      token_expires_at: expires_at,
      scope: attrs[:scope] || attrs["scope"],
      status: "connected"
    }

    case get_account() do
      nil ->
        %GoogleAccount{}
        |> GoogleAccount.changeset(params)
        |> Repo.insert()

      account ->
        # If refresh_token is nil in new params, preserve existing
        params =
          if is_nil(params.refresh_token) do
            Map.delete(params, :refresh_token)
          else
            params
          end

        account
        |> GoogleAccount.changeset(params)
        |> Repo.update()
    end
  end

  @doc """
  Retrieves a valid access token. If the current token expires within 120 seconds,
  it refreshes the token automatically.
  """
  def get_valid_access_token do
    case get_account() do
      nil ->
        {:error, :not_connected}

      %GoogleAccount{status: "invalid_grant"} ->
        {:error, :invalid_grant}

      %GoogleAccount{refresh_token: nil} ->
        {:error, :missing_refresh_token}

      %GoogleAccount{} = account ->
        now = DateTime.utc_now()
        # Refresh if expires in less than 120 seconds
        needs_refresh =
          is_nil(account.token_expires_at) or
            DateTime.diff(account.token_expires_at, now, :second) < 120

        if needs_refresh do
          refresh_account_token(account)
        else
          {:ok, account.access_token}
        end
    end
  end

  @doc """
  Refreshes account token and updates database.
  """
  def refresh_account_token(%GoogleAccount{} = account) do
    case OAuth.refresh_token(account.refresh_token) do
      {:ok, tokens} ->
        {:ok, updated_account} = save_tokens(tokens)
        {:ok, updated_account.access_token}

      {:error, :invalid_grant} ->
        account
        |> GoogleAccount.changeset(%{status: "invalid_grant"})
        |> Repo.update()

        {:error, :invalid_grant}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Disconnects Google account and clears credentials.
  """
  def disconnect_account do
    case get_account() do
      nil ->
        :ok

      account ->
        if account.refresh_token do
          OAuth.revoke(account.refresh_token)
        end

        Repo.delete(account)
        :ok
    end
  end
end
