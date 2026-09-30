defmodule AskDriveWeb.AppAdminAccessController do
  @moduledoc """
  Getting into an app's admin screen (spec F-1113): only the app's administrators, after
  confirming it is them — their own password through Secure LDAP, or (without LDAP) a
  sign-in within the last 10 minutes. Elevation is remembered per app in the session.
  """
  use AskDriveWeb, :controller

  plug :put_view, html: AskDriveWeb.AdminAccessHTML

  alias AskDrive.Accounts
  alias AskDrive.Accounts.AppAdminAccess
  alias AskDrive.Apps
  alias AskDriveWeb.ConnectionEnv

  plug :load_app when action in [:new, :create, :release]

  def new(conn, _params) do
    app = conn.assigns.app

    case AppAdminAccess.confirmation_method() do
      :ldap_password ->
        render_prompt(conn, nil)

      :fresh_login ->
        at = get_session(conn, :authenticated_at)

        case AppAdminAccess.elevate_with_fresh_login(
               conn.assigns.current_user,
               app,
               at,
               context(conn)
             ) do
          {:ok, token} -> enter(conn, app, token)
          {:error, _} -> render_prompt(conn, nil)
        end
    end
  end

  def create(conn, params) do
    app = conn.assigns.app
    password = get_in(params, ["admin", "password"]) || ""
    env = ConnectionEnv.env(conn)

    case AppAdminAccess.elevate_with_password(
           conn.assigns.current_user,
           app,
           password,
           env,
           context(conn)
         ) do
      {:ok, token} ->
        enter(conn, app, token)

      {:error, :invalid_password} ->
        left = Accounts.LoginThrottle.remaining(conn.assigns.current_user.email)
        render_prompt(conn, "パスワードが正しくありません。（あと #{left} 回失敗すると一時的にロックされます）")

      {:error, {:locked, until}} ->
        render_prompt(conn, "失敗が続いたため、#{AskDrive.Clock.format(until, "%m/%d %H:%M")} まで受け付けません。")

      {:error, {:unavailable, message}} ->
        render_prompt(conn, "LDAP サーバーで確認できませんでした: #{message}")

      {:error, :not_assigned} ->
        not_assigned(conn, app)
    end
  end

  @doc "Sign in again (the proof of identity without LDAP), then back to the app's admin screen."
  def reauth(conn, %{"app" => slug}) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> redirect(to: "/login?" <> URI.encode_query(%{return_to: "/#{slug}/admin/elevate"}))
  end

  def release(conn, _params) do
    app = conn.assigns.app
    tokens = get_session(conn, AppAdminAccess.session_key()) || %{}

    conn
    |> put_session(AppAdminAccess.session_key(), Map.delete(tokens, app.slug))
    |> put_flash(:info, "窓口「#{app.name}」の管理画面から出ました。")
    |> redirect(to: "/" <> app.slug)
  end

  defp enter(conn, app, token) do
    tokens = get_session(conn, AppAdminAccess.session_key()) || %{}

    conn
    |> put_session(AppAdminAccess.session_key(), Map.put(tokens, app.slug, token))
    |> put_flash(:info, "窓口「#{app.name}」の管理画面に入りました。")
    |> redirect(to: back_to(conn, app))
  end

  defp load_app(conn, _opts) do
    case Apps.get_by_slug(conn.path_params["app"]) do
      nil ->
        conn |> redirect(to: ~p"/") |> halt()

      app ->
        if Accounts.assigned_app_admin?(conn.assigns.current_user, app.slug),
          do: assign(conn, :app, app),
          else: conn |> not_assigned(app) |> halt()
    end
  end

  defp not_assigned(conn, app) do
    conn
    |> put_flash(
      :error,
      "窓口「#{app.name}」の管理画面は、この窓口の担当者（窓口管理者）だけが使えます。担当者の追加は、この窓口の担当者か全体管理者に依頼してください。"
    )
    |> redirect(to: "/" <> app.slug)
  end

  defp render_prompt(conn, error) do
    app = conn.assigns.app

    conn
    |> assign(:error_message, error)
    |> assign(:method, AppAdminAccess.confirmation_method())
    |> assign(:fresh_minutes, AppAdminAccess.fresh_login_minutes())
    |> assign(:page_title, "#{app.name} の管理画面へ")
    |> render(:app_elevate)
  end

  defp back_to(conn, app) do
    case get_session(conn, :user_return_to) do
      "/" <> _ = path ->
        if String.starts_with?(path, "/#{app.slug}/admin"), do: path, else: "/#{app.slug}/admin"

      _ ->
        "/#{app.slug}/admin"
    end
  end

  defp context(conn) do
    %{
      ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: conn |> get_req_header("user-agent") |> List.first()
    }
  end
end
