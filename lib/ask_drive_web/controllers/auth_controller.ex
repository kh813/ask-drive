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
  alias AskDrive.Accounts.{AppAdminAccess, LoginThrottle}
  alias AskDrive.Drive.OAuth
  alias AskDrive.Ldap
  alias AskDrive.Settings
  alias AskDriveWeb.UserAuth

  @doc """
  Renders the sign-in page.
  """
  def login(conn, params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/")
    else
      conn
      |> remember_return_to(params["return_to"])
      |> AskDriveWeb.ConnectionEnv.ensure_device_cookie()
      |> assign(:oauth_configured?, OAuth.login_enabled?())
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
      params
      |> get_in(["ldap", "email"])
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> with_default_domain()

    password = params |> get_in(["ldap", "password"]) |> to_string()
    env = AskDriveWeb.ConnectionEnv.env(conn)
    setting = Settings.platform_setting!()

    cond do
      not Ldap.enabled?(setting) ->
        ldap_failed(conn, email, "LDAP ログインは有効になっていません。")

      email == "" or password == "" ->
        ldap_failed(conn, email, "メールアドレスとパスワードを入力してください。")

      match?({:locked, _, _}, LoginThrottle.check(email, env.key)) ->
        {:locked, until, _scope} = LoginThrottle.check(email, env.key)

        ldap_failed(
          conn,
          email,
          "ログインの失敗が続いたため、#{AskDrive.Clock.format(until, "%m/%d %H:%M")} まで受け付けません。急ぐ場合は管理者にロックの解除を依頼してください。"
        )

      true ->
        # signing in may answer from the 24-hour cache (F-1311); admin screens never do
        case Ldap.authenticate(setting, email, password, remember: true) do
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

  # only a path on this site (not "//host" or a full URL), so it can't redirect elsewhere
  defp remember_return_to(conn, "/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]),
      do: conn,
      else: put_session(conn, :user_return_to, path)
  end

  defp remember_return_to(conn, _), do: conn

  defp ldap_enabled? do
    Ldap.enabled?(Settings.platform_setting!())
  rescue
    _ -> false
  end

  @doc """
  Starts the employee sign-in flow.
  """
  def request(conn, params) do
    if OAuth.login_enabled?() do
      conn
      |> delete_session(:oauth_redirect_uri)
      |> start_oauth(:login, params["return_to"] || "/")
    else
      conn
      |> put_flash(:error, "Google ログインは無効になっています。")
      |> redirect(to: ~p"/login")
    end
  end

  @doc """
  Starts the Drive sync account authorization flow (administrators only).
  """
  def request_drive(conn, params) do
    if drive_manager?(conn, params["app"]) do
      # The callback URL is shared by every app, so remember which app is authorizing (6.11)
      # From a browser on the server itself, Google can come straight back to AskDrive on a
      # loopback address (a "desktop app" OAuth client accepts any loopback port without
      # registering it): no pasting (F-348). The address must use the host the browser is
      # on, so the session cookie comes along.
      redirect_uri =
        if params["loopback"] == "1" and loopback_host?(conn.host),
          do: OAuth.manual_redirect_uri()

      extra =
        case String.trim(params["hint"] || "") do
          "" -> %{}
          hint -> %{login_hint: hint}
        end

      conn
      |> put_session(:oauth_app, params["app"])
      |> put_session(:oauth_redirect_uri, redirect_uri)
      |> start_oauth(:drive, params["return_to"] || "/admin?tab=settings", extra)
    else
      not_drive_manager(conn, params["app"])
    end
  end

  # A desk's Drive sync account belongs to its settings: its administrators, inside its
  # admin screen (the per-desk elevation of F-1113), may (re)authorize or revoke it — not
  # platform administrators who aren't assigned to it. Guest mode lets everyone in.
  defp drive_manager?(conn, slug) do
    app = desk(slug)
    tokens = get_session(conn, AppAdminAccess.session_key()) || %{}

    UserAuth.auth_disabled?() or
      (is_map(conn.assigns[:current_user]) and
         AppAdminAccess.elevated?(tokens[app.slug], conn.assigns.current_user, app))
  end

  defp not_drive_manager(conn, slug) do
    app = desk(slug)

    conn
    |> clear_oauth_session()
    |> put_flash(:error, "Google Drive の連携は、窓口「#{app.name}」の管理画面に入っている窓口管理者だけが行えます。")
    |> redirect(to: "/#{app.slug}/admin?tab=settings")
  end

  defp desk(slug), do: AskDrive.Apps.get_by_slug(slug || "") || AskDrive.Apps.primary()

  defp start_oauth(conn, flow, return_to, extra \\ %{}) do
    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    # the Drive flow uses the desk's own OAuth client when it has one (F-346)
    {client_id, url} =
      in_flow_context(conn, flow, fn ->
        {OAuth.client(flow) |> elem(0),
         OAuth.authorize_url(state, redirect_uri(conn), flow, extra)}
      end)

    if client_id == "" do
      conn
      |> put_flash(
        :error,
        if(flow == :drive,
          do: "Google Drive 同期の OAuth クライアント ID / シークレットが未設定です。窓口の「Google Drive 同期設定」で設定してください。",
          else: "Google OAuth の Client ID / Secret が未設定です。全体設定で設定してください。"
        )
      )
      |> redirect(to: fallback_path(conn, flow))
    else
      conn
      |> put_session(:oauth_state, state)
      |> put_session(:oauth_flow, Atom.to_string(flow))
      |> put_session(:oauth_return_to, return_to)
      |> redirect(external: url)
    end
  end

  # The Drive flow reads the authorizing desk's settings (its OAuth client); login, the
  # platform's
  defp in_flow_context(conn, flow, fun) when flow in [:drive, "drive"],
    do: in_app(get_session(conn, :oauth_app), fun)

  defp in_flow_context(_conn, _flow, fun), do: fun.()

  defp flow_atom("drive"), do: :drive
  defp flow_atom(_), do: :login

  @doc """
  Handles the shared OAuth callback for whichever flow the session recorded.
  """
  # A Drive authorization started from a desk's admin screen (F-352): Google brought the
  # browser back here — on the server itself, or to a host name AskDrive answers on. The
  # state names it, and its PKCE verifier never left the server, so no session is needed.
  def callback(conn, %{"state" => state} = params) when is_binary(state) and state != "" do
    if AskDrive.Drive.PendingAuth.pending?(state),
      do: finish_pending_drive_auth(conn, state, params),
      else: session_callback(conn, params)
  end

  def callback(conn, params), do: session_callback(conn, params)

  defp finish_pending_drive_auth(conn, state, params) do
    auth = AskDrive.Drive.PendingAuth.take(state)

    result =
      cond do
        is_nil(auth) ->
          {:error, "この認可は期限が切れました。AskDrive の画面で「接続」からやり直してください。"}

        params["error"] ->
          {:error, "Google で許可されませんでした（#{params["error"]}）。"}

        true ->
          in_app(auth.app, fn ->
            with {:ok, tokens} <-
                   OAuth.exchange_manual_code(params["code"], auth.verifier, auth.redirect_uri),
                 :ok <- drive_account_in_domain(tokens[:email]),
                 {:ok, account} <- Accounts.save_tokens(tokens) do
              {:ok, account}
            end
          end)
      end

    case result do
      {:ok, account} ->
        app = desk(auth.app)

        Phoenix.PubSub.broadcast(
          AskDrive.PubSub,
          "drive_auth:" <> app.slug,
          {:drive_connected, account.email}
        )

        drive_auth_page(
          conn,
          :ok,
          "Google Drive と接続しました（#{account.email}）。このウィンドウを閉じて、AskDrive の画面に戻ってください。"
        )

      {:error, {:domain, domain}} ->
        drive_auth_page(conn, :error, "組織のドメイン（@#{domain}）のアカウントで認可してください。")

      {:error, message} when is_binary(message) ->
        drive_auth_page(conn, :error, message)

      {:error, reason} ->
        drive_auth_page(conn, :error, "トークンを取得できませんでした: #{inspect(reason)}")
    end
  end

  defp drive_account_in_domain(email) do
    domain = Settings.platform_setting!().allowed_domain

    cond do
      domain in [nil, ""] ->
        :ok

      is_binary(email) and
          String.ends_with?(String.downcase(email), "@" <> String.downcase(domain)) ->
        :ok

      true ->
        {:error, {:domain, domain}}
    end
  end

  # a page of its own: this is the window Google opened, not the admin screen
  defp drive_auth_page(conn, status, message) do
    color = if status == :ok, do: "#047857", else: "#b91c1c"
    message = message |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      if(status == :ok, do: 200, else: 400),
      ~s(<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>AskDrive</title></head><body style="font-family:sans-serif;max-width:36rem;margin:4rem auto;padding:0 1rem"><h1 style="font-size:1.1rem">AskDrive — Google Drive 同期</h1><p id="drive-auth-result" style="color:#{color}">#{message}</p></body></html>)
    )
  end

  defp session_callback(conn, %{"code" => code, "state" => state}) do
    session_state = get_session(conn, :oauth_state)
    flow = get_session(conn, :oauth_flow) || "login"
    return_to = get_session(conn, :oauth_return_to) || "/"

    cond do
      is_nil(session_state) or session_state != state ->
        conn
        |> clear_oauth_session()
        |> put_flash(:error, "不正な認証リクエスト (state 不一致) です。もう一度お試しください。")
        |> redirect(to: fallback_path(conn, flow))

      flow == "drive" and not drive_manager?(conn, get_session(conn, :oauth_app)) ->
        not_drive_manager(conn, get_session(conn, :oauth_app))

      true ->
        exchange = fn -> OAuth.exchange_code(code, redirect_uri(conn), flow_atom(flow)) end

        case in_flow_context(conn, flow, exchange) do
          {:ok, tokens} -> complete(conn, flow, tokens, return_to)
          {:error, reason} -> auth_failed(conn, flow, "Google 認証に失敗しました: #{inspect(reason)}")
        end
    end
  end

  defp session_callback(conn, %{"error" => error}) do
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
    if drive_manager?(conn, params["app"]) do
      in_app(params["app"], &Accounts.disconnect_account/0)

      conn
      |> put_flash(:info, "Google アカウントの連携を解除しました。")
      |> redirect(to: params["return_to"] || ~p"/admin?tab=settings")
    else
      not_drive_manager(conn, params["app"])
    end
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
    |> delete_session(:oauth_redirect_uri)
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

  # "name" alone means name@<the organization's domain> (F-1312); the page fills it in too,
  # this covers a browser without JavaScript. Any other domain is taken as typed: the
  # directory itself decides who exists — a Workspace may have secondary domains.
  defp with_default_domain(""), do: ""

  defp with_default_domain(email) do
    case {String.contains?(email, "@"), allowed_domain()} do
      {false, domain} when is_binary(domain) -> email <> "@" <> String.downcase(domain)
      _ -> email
    end
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
  defp loopback_host?(host), do: host == "localhost"

  # the redirect URI this authorization was started with (the loopback one, F-348), else this
  # request's own callback URL — the token exchange must name the same one
  defp redirect_uri(conn), do: get_session(conn, :oauth_redirect_uri) || callback_url(conn)

  defp callback_url(conn) do
    port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port_suffix}/auth/google/callback"
  end
end
