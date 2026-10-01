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

  # Authorizing the Drive service account and signing a person in are different flows with
  # different scopes, but they share one callback URI so Google Cloud Console only ever
  # needs a single redirect entry (spec 6.9).
  @drive_scopes [
    "https://www.googleapis.com/auth/drive.readonly",
    "https://www.googleapis.com/auth/userinfo.email"
  ]

  @login_scopes [
    "openid",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile"
  ]

  @doc """
  Scopes requested for the given flow.
  """
  def scopes(:login), do: @login_scopes
  def scopes(_drive), do: @drive_scopes

  @doc """
  Generates the Google OAuth authorization URL for `:drive` (default) or `:login`.

  Only the Drive flow asks for offline access: sign-in needs no refresh token, and asking
  for one would store a long-lived credential per employee for no reason (N-605).
  """
  def authorize_url(state, redirect_uri, flow \\ :drive) do
    base = %{
      client_id: get_client_id(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: Enum.join(scopes(flow), " "),
      state: state
    }

    params =
      case flow do
        :login -> Map.put(base, :prompt, "select_account")
        _drive -> Map.merge(base, %{access_type: "offline", prompt: "consent"})
      end

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
        userinfo =
          case fetch_userinfo(body["access_token"]) do
            {:ok, info} -> info
            _ -> %{}
          end

        {:ok,
         %{
           access_token: body["access_token"],
           refresh_token: body["refresh_token"],
           expires_in: body["expires_in"],
           scope: body["scope"],
           email: userinfo["email"],
           name: userinfo["name"],
           picture: userinfo["picture"]
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

  @doc """
  Whether employees can sign in with Google (spec F-1310): switched on (platform setting)
  and a client ID configured. Only the sign-in flow; Drive sync's OAuth doesn't depend on it.
  """
  def login_enabled? do
    get_client_id() != "" and AskDrive.Settings.platform_setting!().oauth_login_enabled != false
  rescue
    _ -> get_client_id() != ""
  end

  @doc """
  Whether the platform's Google OAuth client (ID and secret) is configured — needed for Google
  login and for a desk's Drive sync by OAuth (F-345).
  """
  def client_configured?, do: get_client_id() != "" and get_client_secret() != ""

  # The OAuth client is the platform's (set in Platform Settings, spec F-1104), also when a
  # desk authorizes Drive: a desk's own settings row only holds a copy taken at its creation.
  def get_client_id do
    case AskDrive.Settings.platform_setting() do
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
    case AskDrive.Settings.platform_setting() do
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
