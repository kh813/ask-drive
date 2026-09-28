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

  ## Domain-wide delegation (spec F-121)

  A service account is always an identity outside the Workspace organization, so a shared
  drive restricted to "people inside the organization" can never be shared with it. For that
  case a Workspace super admin grants the service account's `client_id` domain-wide
  delegation for the `drive.readonly` scope, and AskDrive puts a `sub` claim (the user to act
  as) into the JWT. Google then issues a token for that user, and Drive sees an insider.

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
         client_id: decoded["client_id"],
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
  def get_valid_access_token(json, subject \\ nil) when is_binary(json) do
    GenServer.call(__MODULE__, {:get_token, json, presence(subject)}, 30_000)
  end

  @doc """
  Mints a fresh access token unconditionally, bypassing the cache. Used for the settings
  screen's "接続テスト" so a stale cached failure can't hide a fix (F-807's Drive equivalent).
  """
  def fetch_access_token(json, subject \\ nil) when is_binary(json) do
    with {:ok, account} <- parse(json) do
      request_token(account, presence(subject))
    end
  end

  # --- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get_token, json, subject}, _from, state) do
    # Keyed on the subject too: changing who is impersonated must not reuse a token minted
    # for someone else.
    key = :crypto.hash(:sha256, [json, 0, subject || ""])
    now = System.system_time(:second)

    case Map.get(state, key) do
      %{token: token, expires_at: expires_at} when expires_at - now > @refresh_margin_seconds ->
        {:reply, {:ok, token}, state}

      _ ->
        case parse(json) do
          {:ok, account} ->
            case request_token(account, subject) do
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
  def build_assertion(account, subject \\ nil) do
    now = System.system_time(:second)

    claims =
      %{
        iss: account.client_email,
        scope: @scope,
        aud: account.token_uri,
        iat: now,
        exp: now + @assertion_lifetime_seconds
      }
      |> maybe_put_sub(subject)

    sign_jwt(claims, account.private_key, account.private_key_id)
  end

  # --- Internals ----------------------------------------------------------------

  defp request_token(account, subject) do
    with {:ok, assertion} <- build_assertion(account, subject) do
      exchange(account, subject, assertion)
    end
  end

  defp maybe_put_sub(claims, nil), do: claims
  defp maybe_put_sub(claims, subject), do: Map.put(claims, :sub, subject)

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

  defp exchange(account, subject, assertion) do
    body = %{grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: assertion}

    case Req.post(account.token_uri, form: body, retry: false) do
      {:ok, %{status: 200, body: %{"access_token" => token} = resp}} ->
        {:ok,
         %{access_token: token, expires_in: resp["expires_in"] || @assertion_lifetime_seconds}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Service account token exchange failed (HTTP #{status}): #{inspect(body)}")
        {:error, describe_exchange_error(status, body, account, subject)}

      {:error, reason} ->
        Logger.error("Service account token exchange network failure: #{inspect(reason)}")
        {:error, "接続できませんでした: #{inspect(reason)}"}
    end
  end

  @doc false
  # Google's token endpoint answers a missing or wrong delegation with a bare
  # "unauthorized_client" / "invalid_grant", which on its own says nothing about the admin
  # console step that fixes it. Spell that step out, with the exact values to register.
  def describe_exchange_error(_status, %{"error" => "unauthorized_client"}, account, subject)
      when is_binary(subject) do
    "ドメイン全体の委任が許可されていません。Google 管理コンソール →「セキュリティ」→「API の制御」→" <>
      "「ドメイン全体の委任」で、クライアント ID #{account[:client_id] || "(JSON キーの client_id)"} に" <>
      "スコープ #{@scope} を追加してください（反映まで数分〜最大24時間かかることがあります）。"
  end

  def describe_exchange_error(_status, %{"error" => "invalid_grant"} = body, _account, subject)
      when is_binary(subject) do
    "なりすまし先ユーザー #{subject} でトークンを取得できませんでした。Workspace 内に実在する有効な" <>
      "ユーザーのメールアドレスか確認してください（#{body["error_description"] || "invalid_grant"}）。"
  end

  def describe_exchange_error(status, body, _account, _subject) do
    HTTP.describe(HTTP.classify(status, body))
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
