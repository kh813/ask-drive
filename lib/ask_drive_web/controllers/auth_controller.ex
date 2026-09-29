defmodule AskDriveWeb.AuthController do
  @moduledoc """
  Google OAuth for both flows of spec 6.9.

  `flow=login` signs an employee in (`openid email profile`); `flow=drive` authorizes the
  singleton Drive-reading service account (`drive.readonly`). They share one callback URI so
  Google Cloud Console needs only a single redirect entry, and the flow is recovered from
  the session rather than the URL.
  """
  use AskDriveWeb, :controller

  alias AskDrive.Accounts
  alias AskDrive.Accounts.LoginThrottle
  alias AskDrive.Drive.OAuth
  alias AskDrive.Ldap
  alias AskDrive.Settings
  alias AskDriveWeb.UserAuth

  @doc """
  Renders the sign-in page.
  """
  def login(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/")
    else
      conn
      |> ensure_device_cookie()
      |> assign(:oauth_configured?, OAuth.get_client_id() != "")
      |> assign(:ldap_enabled?, ldap_enabled?())
      |> assign(:allowed_domain, allowed_domain())
      |> assign(:page_title, "AskDrive - ログイン")
      |> render(:login)
    end
  end

  @doc """
  Signs an employee in with their Google Workspace e-mail and password, verified by Google
  Secure LDAP (spec 6.13). Throttled per account and per address (LoginThrottle); an
  unknown account and a wrong password get the same answer.
  """
  def ldap_login(conn, params) do
    email =
      params |> get_in(["ldap", "email"]) |> to_string() |> String.trim() |> String.downcase()

    password = params |> get_in(["ldap", "password"]) |> to_string()
    env = connection_env(conn)
    setting = Settings.platform_setting!()

    cond do
      not Ldap.enabled?(setting) ->
        ldap_failed(conn, email, "LDAP ログインは有効になっていません。")

      email == "" or password == "" ->
        ldap_failed(conn, email, "メールアドレスとパスワードを入力してください。")

      domain_denied?(email) ->
        ldap_failed(conn, email, "アクセス拒否: 許可されたドメイン (@#{allowed_domain()}) のアカウントのみログインできます。")

      match?({:locked, _, _}, LoginThrottle.check(email, env.key)) ->
        {:locked, until, _scope} = LoginThrottle.check(email, env.key)

        ldap_failed(
          conn,
          email,
          "ログインの失敗が続いたため、#{AskDrive.Clock.format(until, "%m/%d %H:%M")} まで受け付けません。急ぐ場合は管理者にロックの解除を依頼してください。"
        )

      true ->
        case Ldap.authenticate(setting, email, password) do
          {:ok, %{email: verified, name: name}} ->
            LoginThrottle.clear(email)
            finish_password_login(conn, %{email: verified, name: name})

          {:error, :invalid_credentials} ->
            LoginThrottle.record_failure(email, env, "invalid_credentials")
            left = LoginThrottle.remaining(email)

            ldap_failed(
              conn,
              email,
              "メールアドレスまたはパスワードが違います。" <>
                if(left > 0, do: "（あと #{left} 回失敗すると一時的にロックされます）", else: "")
            )

          {:error, {:unavailable, message}} ->
            ldap_failed(conn, email, "LDAP サーバーで確認できませんでした: #{message}")
        end
    end
  end

  defp finish_password_login(conn, attrs) do
    case Accounts.upsert_user_from_login(attrs) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "#{user.name || user.email} としてログインしました。")
        |> UserAuth.log_in_user(user)

      {:error, :disabled} ->
        ldap_failed(conn, attrs.email, "このアカウントは無効化されています。管理者にお問い合わせください。")

      {:error, _changeset} ->
        ldap_failed(conn, attrs.email, "ログイン情報を保存できませんでした。")
    end
  end

  defp ldap_failed(conn, email, message) do
    conn
    |> put_flash(:error, message)
    |> put_flash(:ldap_email, email)
    |> redirect(to: ~p"/login")
  end

  # The browser's device cookie (spec F-1305): a random id set on the login page, so the
  # 24-hour lock applies to one browser, not to everyone behind the office NAT.
  @device_cookie "_askdrive_device"
  @device_cookie_opts [sign: true, max_age: 400 * 86_400, http_only: true, same_site: "Lax"]

  defp ensure_device_cookie(conn) do
    conn = fetch_cookies(conn, signed: [@device_cookie])

    if conn.cookies[@device_cookie] do
      conn
    else
      id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
      put_resp_cookie(conn, @device_cookie, id, @device_cookie_opts)
    end
  end

  defp connection_env(conn) do
    conn = fetch_cookies(conn, signed: [@device_cookie])
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    ua = conn |> get_req_header("user-agent") |> List.first()
    lang = conn |> get_req_header("accept-language") |> List.first()

    %{
      key: LoginThrottle.env_key(conn.cookies[@device_cookie], ip, ua, lang),
      ip: ip,
      user_agent: ua
    }
  end

  defp ldap_enabled? do
    Ldap.enabled?(Settings.platform_setting!())
  rescue
    _ -> false
  end

  @doc """
  Starts the employee sign-in flow.
  """
  def request(conn, params), do: start_oauth(conn, :login, params["return_to"] || "/")

  @doc """
  Starts the Drive sync account authorization flow (administrators only).
  """
  def request_drive(conn, params) do
    # The callback URL is shared by every app, so remember which app is authorizing (6.11)
    conn
    |> put_session(:oauth_app, params["app"])
    |> start_oauth(:drive, params["return_to"] || "/admin?tab=settings")
  end

  defp start_oauth(conn, flow, return_to) do
    if OAuth.get_client_id() == "" do
      conn
      |> put_flash(
        :error,
        "Google OAuth の Client ID / Secret が未設定です。.env.prod または管理画面で設定してください。"
      )
      |> redirect(to: fallback_path(conn, flow))
    else
      state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

      conn
      |> put_session(:oauth_state, state)
      |> put_session(:oauth_flow, Atom.to_string(flow))
      |> put_session(:oauth_return_to, return_to)
      |> redirect(external: OAuth.authorize_url(state, callback_url(conn), flow))
    end
  end

  @doc """
  Handles the shared OAuth callback for whichever flow the session recorded.
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    session_state = get_session(conn, :oauth_state)
    flow = get_session(conn, :oauth_flow) || "login"
    return_to = get_session(conn, :oauth_return_to) || "/"

    cond do
      is_nil(session_state) or session_state != state ->
        conn
        |> clear_oauth_session()
        |> put_flash(:error, "不正な認証リクエスト (state 不一致) です。もう一度お試しください。")
        |> redirect(to: fallback_path(conn, flow))

      flow == "drive" and not conn.assigns[:admin_elevated?] ->
        conn
        |> clear_oauth_session()
        |> put_flash(:error, "Drive 連携は管理者権限に昇格したセッションでのみ実行できます。")
        |> redirect(to: ~p"/")

      true ->
        case OAuth.exchange_code(code, callback_url(conn)) do
          {:ok, tokens} -> complete(conn, flow, tokens, return_to)
          {:error, reason} -> auth_failed(conn, flow, "Google 認証に失敗しました: #{inspect(reason)}")
        end
    end
  end

  def callback(conn, %{"error" => error}) do
    flow = get_session(conn, :oauth_flow) || "login"
    auth_failed(conn, flow, "Google 認証がキャンセルまたは失敗しました: #{error}")
  end

  @doc """
  Ends the session.
  """
  def logout(conn, _params) do
    conn
    |> put_flash(:info, "ログアウトしました。")
    |> UserAuth.log_out_user()
  end

  @doc """
  Revokes and forgets the Drive sync account (administrators only).
  """
  def disconnect(conn, params) do
    in_app(params["app"], &Accounts.disconnect_account/0)

    conn
    |> put_flash(:info, "Google アカウントの連携を解除しました。")
    |> redirect(to: params["return_to"] || ~p"/admin?tab=settings")
  end

  # Runs `fun` in the named app's database (the Drive sync account is per app, spec 6.11);
  # without an app — or an unknown one — in the primary app, as before apps existed.
  defp in_app(slug, fun) do
    app = AskDrive.Apps.get_by_slug(slug || "") || AskDrive.Apps.primary()
    AskDrive.Apps.with_app(app, fun)
  end

  # --- Flow completion ------------------------------------------------------

  defp complete(conn, "drive", tokens, return_to) do
    email = tokens[:email] || ""

    if domain_denied?(email) do
      auth_failed(
        conn,
        "drive",
        "アクセス拒否: 許可されたドメイン (@#{allowed_domain()}) のアカウントのみ連携できます。"
      )
    else
      {:ok, account} =
        in_app(get_session(conn, :oauth_app), fn -> Accounts.save_tokens(tokens) end)

      conn
      |> clear_oauth_session()
      |> put_flash(:info, "Google Drive 同期アカウント (#{account.email || "Drive"}) と連携しました。")
      |> redirect(to: return_to)
    end
  end

  defp complete(conn, _login, tokens, return_to) do
    email = tokens[:email] || ""

    cond do
      email == "" ->
        auth_failed(conn, "login", "Google からメールアドレスを取得できませんでした。")

      domain_denied?(email) ->
        auth_failed(
          conn,
          "login",
          "アクセス拒否: 許可されたドメイン (@#{allowed_domain()}) のアカウントのみログインできます。"
        )

      true ->
        case Accounts.upsert_user_from_login(tokens) do
          {:ok, user} ->
            conn
            |> clear_oauth_session()
            |> put_flash(:info, "#{user.name || user.email} としてログインしました。")
            |> UserAuth.log_in_user(user, return_to: return_to)

          {:error, :disabled} ->
            auth_failed(conn, "login", "このアカウントは無効化されています。管理者にお問い合わせください。")

          {:error, _changeset} ->
            auth_failed(conn, "login", "ログイン情報を保存できませんでした。")
        end
    end
  end

  defp auth_failed(conn, flow, message) do
    conn
    |> clear_oauth_session()
    |> put_flash(:error, message)
    |> redirect(to: fallback_path(conn, flow))
  end

  # --- Helpers --------------------------------------------------------------

  defp clear_oauth_session(conn) do
    conn
    |> delete_session(:oauth_state)
    |> delete_session(:oauth_flow)
    |> delete_session(:oauth_return_to)
    |> delete_session(:oauth_app)
  end

  defp fallback_path(conn, flow) when flow in [:drive, "drive"] do
    if conn.assigns[:current_user], do: ~p"/admin?tab=settings", else: ~p"/login"
  end

  defp fallback_path(_conn, _flow), do: ~p"/login"

  defp allowed_domain do
    case Settings.get_setting() do
      %{allowed_domain: domain} when is_binary(domain) ->
        domain = String.trim(domain)
        if domain == "", do: nil, else: domain

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp domain_denied?(email) do
    case allowed_domain() do
      nil -> false
      domain -> not String.ends_with?(String.downcase(email), "@" <> String.downcase(domain))
    end
  end

  # Deliberately built from the actual request rather than `url(~p"...")`: the latter uses
  # the endpoint's static `:url` config (`PHX_HOST`, typically "localhost" for the machine
  # that ran initial setup), so it would send Google the same redirect_uri no matter which
  # host the browser actually used. On a LAN, the admin sets things up via localhost but
  # employees reach the app by IP or hostname — those requests need their own host reflected
  # here, or Google redirects the callback back to "localhost" from the employee's own
  # machine, which has nothing listening on it. Whichever host ends up here must also be
  # registered as an authorized redirect URI in Google Cloud Console (it accepts more than
  # one per OAuth client, so both localhost and the LAN address can be registered together).
  defp callback_url(conn) do
    port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port_suffix}/auth/google/callback"
  end
end
