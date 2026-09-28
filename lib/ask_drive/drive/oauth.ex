defmodule AskDrive.Drive.OAuth do
  @moduledoc """
  Direct implementation of Google OAuth 2.0 authorization code flow using `Req`.
  No third-party OAuth framework required.
  """
  require Logger

  @auth_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @userinfo_endpoint "https://www.googleapis.com/oauth2/v2/userinfo"
  @revoke_endpoint "https://oauth2.googleapis.com/revoke"

  @scopes [
    "https://www.googleapis.com/auth/drive.readonly",
    "https://www.googleapis.com/auth/userinfo.email"
  ]

  @doc """
  Generates the Google OAuth authorization URL.
  """
  def authorize_url(state, redirect_uri) do
    client_id = get_client_id()

    params = %{
      client_id: client_id,
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: Enum.join(@scopes, " "),
      access_type: "offline",
      prompt: "consent",
      state: state
    }

    @auth_endpoint <> "?" <> URI.encode_query(params)
  end

  @doc """
  Exchanges an authorization code for access and refresh tokens.
  """
  def exchange_code(code, redirect_uri) do
    params = %{
      code: code,
      client_id: get_client_id(),
      client_secret: get_client_secret(),
      redirect_uri: redirect_uri,
      grant_type: "authorization_code"
    }

    case Req.post(@token_endpoint, form: params) do
      {:ok, %{status: 200, body: body}} ->
        email =
          case fetch_userinfo(body["access_token"]) do
            {:ok, userinfo} -> userinfo["email"]
            _ -> nil
          end

        {:ok,
         %{
           access_token: body["access_token"],
           refresh_token: body["refresh_token"],
           expires_in: body["expires_in"],
           scope: body["scope"],
           email: email
         }}

      {:ok, %{status: _status, body: body}} ->
        Logger.error("OAuth token exchange failed: #{inspect(body)}")
        {:error, body["error_description"] || body["error"] || "token_exchange_failed"}

      {:error, reason} ->
        Logger.error("OAuth token exchange network error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Refreshes an expired access token using the stored refresh token.
  """
  def refresh_token(refresh_token) do
    params = %{
      client_id: get_client_id(),
      client_secret: get_client_secret(),
      refresh_token: refresh_token,
      grant_type: "refresh_token"
    }

    case Req.post(@token_endpoint, form: params) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           access_token: body["access_token"],
           # If Google doesn't return a new refresh token, caller preserves existing one
           refresh_token: body["refresh_token"],
           expires_in: body["expires_in"],
           scope: body["scope"]
         }}

      {:ok, %{status: 400, body: %{"error" => "invalid_grant"}}} ->
        {:error, :invalid_grant}

      {:ok, %{status: _status, body: body}} ->
        {:error, body["error_description"] || body["error"] || "refresh_failed"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches user info including email.
  """
  def fetch_userinfo(access_token) do
    case Req.get(@userinfo_endpoint, headers: [{"authorization", "Bearer #{access_token}"}]) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Revokes a token (access or refresh).
  """
  def revoke(token) when is_binary(token) do
    case Req.post(@revoke_endpoint, form: %{token: token}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_client_id do
    case AskDrive.Settings.get_setting() do
      %{google_client_id: id} when is_binary(id) and id != "" ->
        id

      _ ->
        Application.get_env(:ask_drive, :google_client_id) ||
          System.get_env("GOOGLE_CLIENT_ID") || ""
    end
  rescue
    _ ->
      Application.get_env(:ask_drive, :google_client_id) ||
        System.get_env("GOOGLE_CLIENT_ID") || ""
  end

  def get_client_secret do
    case AskDrive.Settings.get_setting() do
      %{google_client_secret: secret} when is_binary(secret) and secret != "" ->
        secret

      _ ->
        Application.get_env(:ask_drive, :google_client_secret) ||
          System.get_env("GOOGLE_CLIENT_SECRET") || ""
    end
  rescue
    _ ->
      Application.get_env(:ask_drive, :google_client_secret) ||
        System.get_env("GOOGLE_CLIENT_SECRET") || ""
  end
end
