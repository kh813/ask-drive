defmodule AskDrive.Drive.ServiceAccount do
  @moduledoc """
  Google Service Account (JWT Bearer) authentication for Drive sync — an alternative to the
  OAuth authorization-code flow for the sync-only account (spec 6.1, F-110).

  A service account needs no browser round-trip and no `redirect_uri`, so it sidesteps
  Google's restrictions on OAuth clients entirely: no hostname has to be registered anywhere,
  and there is nothing for a private IP or `.local` address to break. The admin creates a
  service account in Google Cloud Console, downloads its JSON key, and shares the target
  Drive folder with the service account's email address exactly like sharing with any other
  Google user — no domain-wide delegation or Workspace admin console access required for a
  single shared folder.

  Implemented directly on `:public_key`/`:crypto` rather than a JWT dependency, consistent
  with this project's preference for the stdlib over small wrapper libraries (spec 3.4).
  """
  use GenServer
  require Logger

  alias AskDrive.LLM.HTTP

  @scope "https://www.googleapis.com/auth/drive.readonly"
  @default_token_uri "https://oauth2.googleapis.com/token"
  @assertion_lifetime_seconds 3_600
  @refresh_margin_seconds 120

  # --- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Parses a service account JSON key, validating the fields needed to sign requests.
  """
  def parse(json) when is_binary(json) do
    with {:ok, decoded} <- decode_json(json),
         {:ok, email} <- fetch_string(decoded, "client_email"),
         {:ok, private_key} <- fetch_string(decoded, "private_key") do
      {:ok,
       %{
         client_email: email,
         private_key: private_key,
         private_key_id: decoded["private_key_id"],
         token_uri: presence(decoded["token_uri"]) || @default_token_uri,
         project_id: decoded["project_id"]
       }}
    end
  end

  def parse(_), do: {:error, "サービスアカウントの JSON キーを入力してください。"}

  @doc """
  Returns a valid, unexpired access token for `json` (the raw service account key content),
  minting and caching a new one as needed. Cached per distinct key content, so rotating the
  key immediately invalidates the old token rather than serving it until natural expiry.
  """
  def get_valid_access_token(json) when is_binary(json) do
    GenServer.call(__MODULE__, {:get_token, json}, 30_000)
  end

  @doc """
  Mints a fresh access token unconditionally, bypassing the cache. Used for the settings
  screen's "接続テスト" so a stale cached failure can't hide a fix (F-807's Drive equivalent).
  """
  def fetch_access_token(json) when is_binary(json) do
    with {:ok, account} <- parse(json) do
      request_token(account)
    end
  end

  # --- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get_token, json}, _from, state) do
    key = :crypto.hash(:sha256, json)
    now = System.system_time(:second)

    case Map.get(state, key) do
      %{token: token, expires_at: expires_at} when expires_at - now > @refresh_margin_seconds ->
        {:reply, {:ok, token}, state}

      _ ->
        case parse(json) do
          {:ok, account} ->
            case request_token(account) do
              {:ok, %{access_token: token, expires_in: expires_in}} ->
                entry = %{token: token, expires_at: now + expires_in}
                {:reply, {:ok, token}, Map.put(state, key, entry)}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @doc """
  Builds and signs the JWT assertion for `account` without exchanging it for a token.
  Exposed (rather than kept private) so the signature can be verified directly in tests
  without a network call to Google — the RS256 signing is the part actually worth testing.
  """
  def build_assertion(account) do
    now = System.system_time(:second)

    claims = %{
      iss: account.client_email,
      scope: @scope,
      aud: account.token_uri,
      iat: now,
      exp: now + @assertion_lifetime_seconds
    }

    sign_jwt(claims, account.private_key, account.private_key_id)
  end

  # --- Internals ----------------------------------------------------------------

  defp request_token(account) do
    with {:ok, assertion} <- build_assertion(account) do
      exchange(account.token_uri, assertion)
    end
  end

  defp sign_jwt(claims, pem_private_key, key_id) do
    header = %{alg: "RS256", typ: "JWT"} |> maybe_put_kid(key_id)
    signing_input = "#{b64(header)}.#{b64(claims)}"

    with {:ok, private_key} <- decode_private_key(pem_private_key) do
      signature = :public_key.sign(signing_input, :sha256, private_key)
      {:ok, "#{signing_input}.#{Base.url_encode64(signature, padding: false)}"}
    end
  end

  defp maybe_put_kid(header, nil), do: header
  defp maybe_put_kid(header, key_id), do: Map.put(header, :kid, key_id)

  defp decode_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, "private_key を PEM 形式として解釈できませんでした。"}
    end
  rescue
    e -> {:error, "private_key の読み込みに失敗しました: #{Exception.message(e)}"}
  end

  defp b64(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp exchange(token_uri, assertion) do
    body = %{grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: assertion}

    case Req.post(token_uri, form: body, retry: false) do
      {:ok, %{status: 200, body: %{"access_token" => token} = resp}} ->
        {:ok,
         %{access_token: token, expires_in: resp["expires_in"] || @assertion_lifetime_seconds}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Service account token exchange failed (HTTP #{status}): #{inspect(body)}")
        {:error, HTTP.describe(HTTP.classify(status, body))}

      {:error, reason} ->
        Logger.error("Service account token exchange network failure: #{inspect(reason)}")
        {:error, "接続できませんでした: #{inspect(reason)}"}
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, "JSON として解析できません: #{Exception.message(error)}"}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "サービスアカウントの JSON キーに #{key} がありません。"}
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
