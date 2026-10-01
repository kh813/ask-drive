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
      client_id: client(flow) |> elem(0),
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
  def exchange_code(code, redirect_uri, flow \\ :login, extra \\ %{}) do
    {client_id, client_secret} = client(flow)

    params =
      Map.merge(
        %{
          code: code,
          client_id: client_id,
          client_secret: client_secret,
          redirect_uri: redirect_uri,
          grant_type: "authorization_code"
        },
        extra
      )

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
  # only the Drive sync account has a refresh token, so this is always the Drive client
  def refresh_token(refresh_token) do
    {client_id, client_secret} = drive_client()

    params = %{
      client_id: client_id,
      client_secret: client_secret,
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

  # --- Drive sync authorized from the administrator's own browser (F-347) -------------
  #
  # Google sends the browser back to a loopback address on the administrator's own PC, where
  # nothing answers: the address bar then holds the code, which is pasted into AskDrive and
  # exchanged by the server. No public URL of the server is involved, so it works wherever
  # the server sits (client/server, LAN only, behind a proxy). PKCE ties the code to the
  # authorization the screen started.

  @manual_redirect "http://localhost"

  def manual_redirect_uri, do: @manual_redirect

  @doc """
  Starts a Drive authorization to finish by pasting: `%{url:, state:, verifier:}`.
  `login_hint` (an e-mail) preselects the account to sync with.
  """
  def manual_authorization(login_hint \\ nil) do
    state = random_token()
    verifier = random_token() <> random_token()
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    params =
      %{
        client_id: elem(drive_client(), 0),
        redirect_uri: @manual_redirect,
        response_type: "code",
        scope: Enum.join(@drive_scopes, " "),
        state: state,
        access_type: "offline",
        prompt: "consent",
        code_challenge: challenge,
        code_challenge_method: "S256"
      }
      |> then(
        &if(present?(login_hint), do: Map.put(&1, :login_hint, String.trim(login_hint)), else: &1)
      )

    %{url: @auth_endpoint <> "?" <> URI.encode_query(params), state: state, verifier: verifier}
  end

  @doc """
  The code from what was pasted — the whole address (`http://localhost/?state=…&code=…`) or
  the code alone. `{:ok, code}`, `{:error, :state_mismatch}` (another authorization's
  address) or `{:error, :no_code}`; `{:error, {:denied, reason}}` when Google reports one.
  """
  def code_from_paste(text, state) do
    text = text |> to_string() |> String.trim()

    cond do
      text == "" ->
        {:error, :no_code}

      String.contains?(text, "?") or String.starts_with?(text, "http") ->
        query = text |> URI.parse() |> Map.get(:query) |> Kernel.||("") |> URI.decode_query()

        cond do
          query["error"] -> {:error, {:denied, query["error"]}}
          query["state"] && query["state"] != state -> {:error, :state_mismatch}
          present?(query["code"]) -> {:ok, query["code"]}
          true -> {:error, :no_code}
        end

      true ->
        {:ok, text}
    end
  end

  @doc "Exchanges a pasted code for the Drive sync account's tokens (with the PKCE verifier)."
  def exchange_manual_code(code, verifier),
    do: exchange_code(code, @manual_redirect, :drive, %{code_verifier: verifier})

  defp random_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  @doc """
  The OAuth client for a flow: Google login uses the platform's; Drive sync uses the current
  desk's own client when it has one (F-346), otherwise the platform's. Call it in the desk's
  context (its database) for the Drive flow.
  """
  def client(:login), do: {get_client_id(), get_client_secret()}
  def client(_drive), do: drive_client()

  def drive_client do
    case AskDrive.Settings.get_setting() do
      %{drive_oauth_client_id: id, drive_oauth_client_secret: secret}
      when is_binary(id) and id != "" and is_binary(secret) and secret != "" ->
        {String.trim(id), secret}

      _ ->
        {get_client_id(), get_client_secret()}
    end
  rescue
    _ -> {get_client_id(), get_client_secret()}
  end

  @doc "Whether the current desk can authorize Drive sync by OAuth (its own client or the platform's)."
  def drive_client_configured? do
    {id, secret} = drive_client()
    id != "" and secret != ""
  end

  @doc "Whether the current desk has an OAuth client of its own for Drive sync (F-346)."
  def desk_drive_client? do
    case AskDrive.Settings.get_setting() do
      %{drive_oauth_client_id: id} when is_binary(id) and id != "" -> true
      _ -> false
    end
  rescue
    _ -> false
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
