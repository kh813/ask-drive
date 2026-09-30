defmodule AskDriveWeb.UserAuth do
  @moduledoc """
  Session handling, authentication and administrator elevation (spec 6.9).

  Signing in never grants administrator rights. Elevation is a separate, password-protected
  step that lives in the session and expires on its own, in the manner of `sudo`. Both the
  controller pipeline and the LiveView `on_mount` hooks enforce it server-side: hiding the
  admin link in the UI is a convenience, not the control (N-609).

  ## Disabling authentication entirely (POC / trusted-LAN mode)

  During the POC this is the default (`:auth_disabled_by_default` in config): login and admin
  elevation are bypassed everywhere, treating every request as an already-elevated
  administrator. `ASK_DRIVE_DISABLE_AUTH=false` restores the normal flow; `=true` forces the
  bypass regardless of the default. This exists for an early
  proof-of-concept phase on a trusted internal LAN, where per-user Google login isn't
  finished yet and getting it working isn't the point of the exercise. It is an explicit,
  server-side environment variable rather than a database setting or a web-UI toggle:
  something this security-relevant should require deploy-time access to the machine to
  change, not be a click away for whoever happens to be signed in.

  Anyone who can reach the app at all gets full chat and admin access with no accountability
  for who did what — do not use this outside a trusted LAN, and re-enable proper
  authentication (a real admin password at minimum) before any wider rollout.
  """
  use AskDriveWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias AskDrive.Accounts
  alias AskDrive.Accounts.{AdminAccess, User}
  alias Phoenix.LiveView

  @session_key :user_id
  @return_to_key :user_return_to
  @elevated_at_key :admin_elevated_at
  @elevated_user_key :admin_elevated_user_id

  # Not a persisted row (id 0 never occurs in SQLite's autoincrement), so it can never be
  # confused with — or accidentally modified as if it were — a real user.
  @guest_admin %User{
    id: 0,
    email: "poc@localhost",
    name: "ゲスト（認証無効・POC モード）",
    admin_eligible: true,
    status: "active"
  }

  @doc """
  Whether login and elevation are bypassed: `ASK_DRIVE_DISABLE_AUTH` when it holds a
  recognisable boolean, otherwise the configured default. See the moduledoc before using this outside the
  call sites that already exist (`fetch_current_user/2`, `assign_current_user/2`, and the
  startup health check's log line).
  """
  def auth_disabled?, do: auth_mode() |> elem(0) == :disabled

  @doc """
  `{:enabled | :disabled, source}` — where the mode comes from (spec F-1308):

    * `:env` — `ASK_DRIVE_DISABLE_AUTH` in `.env.prod` fixes it (the screen and
      `./app.sh auth` can't change it until that line is removed);
    * `:setting` — chosen on the admin screen or with `./app.sh auth` (read on every
      request, so a change applies at once, without a restart);
    * `:default` — nothing chosen yet: the configured default (the POC runs without login).
  """
  def auth_mode do
    value = System.get_env("ASK_DRIVE_DISABLE_AUTH", "") |> String.trim() |> String.downcase()

    cond do
      value in ["true", "1", "yes", "on"] ->
        {:disabled, :env}

      value in ["false", "0", "no", "off"] ->
        {:enabled, :env}

      is_boolean(required = stored_auth_required()) ->
        {if(required, do: :enabled, else: :disabled), :setting}

      Application.get_env(:ask_drive, :auth_disabled_by_default, false) ->
        {:disabled, :default}

      true ->
        {:enabled, :default}
    end
  end

  defp stored_auth_required do
    AskDrive.Settings.platform_setting!().auth_required
  rescue
    # before the first migration, or the database briefly unavailable: fall back
    _ -> nil
  end

  # --- Session lifecycle ----------------------------------------------------

  @doc """
  Starts a session for `user` and redirects to wherever they were headed.

  The session is renewed first so a pre-authentication session id cannot be reused
  afterwards (N-619/N-611).
  """
  def log_in_user(conn, %User{} = user, params \\ %{}) do
    return_to = get_session(conn, @return_to_key)

    conn
    |> renew_session()
    |> put_session(@session_key, user.id)
    |> put_session(:live_socket_id, "users_sessions:#{user.id}")
    |> redirect(to: return_to || params[:return_to] || ~p"/")
  end

  @doc """
  Drops the session and returns to the login page.
  """
  def log_out_user(conn) do
    conn
    |> renew_session()
    |> redirect(to: ~p"/login")
  end

  @doc """
  Marks the session as elevated. The session id is rotated again, so a session id captured
  before elevation cannot be replayed with administrator rights (N-611).
  """
  def elevate_session(conn, %User{} = user) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, user.id)
    |> put_session(:live_socket_id, "users_sessions:#{user.id}")
    |> put_session(@elevated_at_key, System.system_time(:second))
    |> put_session(@elevated_user_key, user.id)
    |> assign(:admin_elevated?, true)
  end

  @doc """
  Drops administrator rights while keeping the user signed in.
  """
  def release_elevation(conn) do
    conn
    |> delete_session(@elevated_at_key)
    |> delete_session(@elevated_user_key)
    |> assign(:admin_elevated?, false)
    |> assign(:admin_elevation_expires_at, nil)
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  # --- Plugs ----------------------------------------------------------------

  @doc """
  Loads the signed-in user and the current elevation state.

  A user disabled since their last request is treated as signed out (F-918), and an
  elevation whose time limit has passed is dropped and recorded here so the audit trail
  shows when rights actually lapsed rather than when someone next clicked something.
  """
  def fetch_current_user(conn, _opts) do
    if auth_disabled?() do
      conn
      |> assign(:current_user, @guest_admin)
      |> assign(:admin_elevated?, true)
      |> assign(:admin_elevation_expires_at, nil)
    else
      user =
        conn
        |> get_session(@session_key)
        |> Accounts.get_user()
        |> active_or_nil()

      conn
      |> assign(:current_user, user)
      |> resolve_elevation(user)
    end
  end

  defp resolve_elevation(conn, nil) do
    conn
    |> assign(:admin_elevated?, false)
    |> assign(:admin_elevation_expires_at, nil)
  end

  defp resolve_elevation(conn, %User{} = user) do
    elevated_at = get_session(conn, @elevated_at_key)
    elevated_user_id = get_session(conn, @elevated_user_key)

    cond do
      is_nil(elevated_at) or elevated_user_id != user.id ->
        conn
        |> assign(:admin_elevated?, false)
        |> assign(:admin_elevation_expires_at, nil)

      # Eligibility can be revoked while a session is still elevated; drop it immediately
      # rather than waiting for the timer.
      not Accounts.any_admin_eligible?(user) ->
        release_elevation(conn)

      expired?(elevated_at) ->
        AdminAccess.record_expiry(user, request_context(conn))
        release_elevation(conn)

      true ->
        conn
        |> assign(:admin_elevated?, true)
        |> assign(:admin_elevation_expires_at, expires_at(elevated_at))
    end
  end

  defp expired?(elevated_at) do
    System.system_time(:second) - elevated_at >= AdminAccess.session_seconds()
  end

  defp expires_at(elevated_at) do
    DateTime.from_unix!(elevated_at + AdminAccess.session_seconds())
  end

  @doc """
  Halts with a redirect to the login page unless someone is signed in (F-901).
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "続行するにはログインしてください。")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc """
  Halts unless the session currently holds administrator rights (F-911).

  An eligible account that has not elevated is sent to the password prompt; anyone else is
  sent back to the chat, without revealing that an elevation screen exists.
  """
  def require_admin_session(conn, _opts) do
    user = conn.assigns[:current_user]

    cond do
      conn.assigns[:admin_elevated?] ->
        if User.admin_eligible?(user) do
          conn
        else
          conn
          |> put_flash(:error, "全体管理画面は全体管理者のみ利用できます。")
          |> redirect(to: ~p"/")
          |> halt()
        end

      is_nil(user) ->
        require_authenticated_user(conn, [])

      User.admin_eligible?(user) ->
        conn
        |> put_flash(:info, "管理操作を行うには管理者パスワードを入力してください。")
        |> maybe_store_return_to()
        |> redirect(to: ~p"/admin/elevate")
        |> halt()

      true ->
        conn
        |> put_flash(:error, "この操作を行う権限がありません。管理者に依頼してください。")
        |> redirect(to: ~p"/")
        |> halt()
    end
  end

  @doc """
  Halts unless the session is elevated for the app in the path with the app's own password
  (spec F-1113). Only the app's assigned administrators get there; platform administrators
  don't (they can only reset the app's password). While login is off (the POC) the guest
  gets in, as everywhere.
  """
  def require_app_admin_session(conn, _opts) do
    user = conn.assigns[:current_user]
    slug = conn.path_params["app"]

    case app_admin_check(
           user,
           slug,
           get_session(conn, AskDrive.Accounts.AppAdminAccess.session_key())
         ) do
      :ok ->
        conn

      :login ->
        require_authenticated_user(conn, [])

      :elevate ->
        conn
        |> maybe_store_return_to()
        |> redirect(to: "/#{slug}/admin/elevate")
        |> halt()

      {:denied, message} ->
        conn |> put_flash(:error, message) |> redirect(to: "/" <> (slug || "")) |> halt()
    end
  end

  @doc false
  # :ok | :login | :elevate | {:denied, message}
  def app_admin_check(user, slug, tokens) do
    app = AskDrive.Apps.get_by_slug(slug)

    cond do
      auth_disabled?() -> :ok
      is_nil(user) -> :login
      is_nil(app) -> {:denied, "窓口が見つかりません。"}
      AskDrive.Accounts.AppAdminAccess.elevated?((tokens || %{})[app.slug], user, app) -> :ok
      Accounts.assigned_app_admin?(user, app.slug) -> :elevate
      true -> {:denied, "窓口「#{app.name}」の管理画面は、この窓口の担当者（窓口管理者）だけが使えます。"}
    end
  end

  @doc """
  Halts unless the signed-in account is allowed to attempt elevation (F-905).
  """
  def require_admin_eligible(conn, _opts) do
    cond do
      Accounts.any_admin_eligible?(conn.assigns[:current_user]) ->
        conn

      conn.assigns[:current_user] ->
        conn
        |> put_flash(:error, "このアカウントは管理者権限に昇格できません。")
        |> redirect(to: ~p"/")
        |> halt()

      true ->
        require_authenticated_user(conn, [])
    end
  end

  @doc """
  Where to send someone after a successful elevation.
  """
  def pop_return_to(conn, default) do
    {get_session(conn, @return_to_key) || default, delete_session(conn, @return_to_key)}
  end

  @doc """
  Client address and user agent for the audit log.
  """
  def request_context(conn) do
    %{
      ip_address: format_ip(conn.remote_ip),
      user_agent: conn |> get_req_header("user-agent") |> List.first()
    }
  end

  defp format_ip(nil), do: nil

  defp format_ip(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> nil
      address -> to_string(address)
    end
  end

  # --- LiveView hooks -------------------------------------------------------

  @doc """
  `on_mount` hooks matching the plugs above.

    * `:mount_current_user` — assigns `:current_user` and elevation state, no enforcement
    * `:require_authenticated` — redirects to `/login` when signed out
    * `:require_admin_session` — redirects unless the session is currently elevated

  A LiveView cannot write to the session, so an elevation that lapses mid-mount is simply
  treated as absent here; the plug records the expiry on the next HTTP request.
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, assign_current_user(socket, session)}
  end

  # Chat and the portal (spec F-1308): open while login is off (the POC), signed in otherwise
  def on_mount(:require_login_when_enabled, params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      # back to the app after signing in (a LiveView can't write the session; /login keeps it)
      return_to = if params["app"], do: "/" <> params["app"], else: "/"

      {:halt,
       redirect_with(
         socket,
         :info,
         "ログインしてください。",
         ~p"/login?#{%{return_to: return_to}}"
       )}
    end
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, redirect_with(socket, :error, "続行するにはログインしてください。", ~p"/login")}
    end
  end

  def on_mount(:require_admin_session, _params, session, socket) do
    socket = assign_current_user(socket, session)
    user = socket.assigns.current_user

    cond do
      socket.assigns.admin_elevated? ->
        if User.admin_eligible?(user) do
          {:cont, socket}
        else
          {:halt, redirect_with(socket, :error, "全体管理画面は全体管理者のみ利用できます。", ~p"/")}
        end

      is_nil(user) ->
        {:halt, redirect_with(socket, :error, "続行するにはログインしてください。", ~p"/login")}

      User.admin_eligible?(user) ->
        {:halt,
         redirect_with(
           socket,
           :info,
           "管理操作を行うには管理者パスワードを入力してください。",
           ~p"/admin/elevate"
         )}

      true ->
        {:halt, redirect_with(socket, :error, "管理画面は管理者のみ利用できます。", ~p"/")}
    end
  end

  def on_mount(:require_app_admin_session, %{"app" => slug}, session, socket) do
    socket = assign_current_user(socket, session)
    tokens = session[AskDrive.Accounts.AppAdminAccess.session_key()]

    case app_admin_check(socket.assigns.current_user, slug, tokens) do
      :ok ->
        {:cont, Phoenix.Component.assign(socket, :app_admin_elevated?, true)}

      :login ->
        {:halt, redirect_with(socket, :error, "続行するにはログインしてください。", ~p"/login")}

      :elevate ->
        {:halt, redirect_with(socket, :info, "窓口の管理者パスワードを入力してください。", "/#{slug}/admin/elevate")}

      {:denied, message} ->
        {:halt, redirect_with(socket, :error, message, "/" <> slug)}
    end
  end

  def on_mount(:require_app_admin_session, _params, session, socket) do
    on_mount(:require_admin_session, %{}, session, socket)
  end

  defp redirect_with(socket, kind, message, to) do
    socket
    |> LiveView.put_flash(kind, message)
    |> LiveView.redirect(to: to)
  end

  defp assign_current_user(socket, session) do
    if auth_disabled?() do
      socket
      |> Phoenix.Component.assign(:current_user, @guest_admin)
      |> Phoenix.Component.assign(:admin_elevated?, true)
      |> Phoenix.Component.assign(:admin_elevation_expires_at, nil)
    else
      do_assign_current_user(socket, session)
    end
  end

  defp do_assign_current_user(socket, session) do
    user =
      session
      |> Map.get("#{@session_key}")
      |> Accounts.get_user()
      |> active_or_nil()

    elevated_at = Map.get(session, "#{@elevated_at_key}")
    elevated_user_id = Map.get(session, "#{@elevated_user_key}")

    elevated? =
      not is_nil(user) and not is_nil(elevated_at) and elevated_user_id == user.id and
        Accounts.any_admin_eligible?(user) and not expired?(elevated_at)

    socket
    |> Phoenix.Component.assign(:current_user, user)
    |> Phoenix.Component.assign(:admin_elevated?, elevated?)
    |> Phoenix.Component.assign(
      :admin_elevation_expires_at,
      if(elevated?, do: expires_at(elevated_at))
    )
  end

  defp active_or_nil(%User{} = user), do: if(User.active?(user), do: user, else: nil)
  defp active_or_nil(_), do: nil

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, @return_to_key, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
