defmodule AskDriveWeb.AdminAccessController do
  @moduledoc """
  Getting into Platform Admin: `sudo` for AskDrive (spec 6.9). Only platform
  administrators, after confirming it is them — their own password through Secure LDAP, or
  (without LDAP) a sign-in within the last 10 minutes. There is no shared password.

  A controller rather than a LiveView because elevating has to write to the session, which
  a LiveView cannot do.
  """
  use AskDriveWeb, :controller

  alias AskDrive.Accounts.{AdminAccess, AppAdminAccess, LoginThrottle, User}
  alias AskDriveWeb.{ConnectionEnv, UserAuth}

  plug :require_platform_admin when action in [:new, :create, :reauth]

  def new(conn, _params) do
    cond do
      conn.assigns[:admin_elevated?] ->
        redirect(conn, to: ~p"/admin")

      AdminAccess.confirmation_method() == :ldap_password ->
        render_prompt(conn, nil)

      true ->
        at = get_session(conn, :authenticated_at)

        case AdminAccess.elevate_with_fresh_login(
               conn.assigns.current_user,
               at,
               UserAuth.request_context(conn)
             ) do
          {:ok, user} -> enter(conn, user)
          {:error, _} -> render_prompt(conn, nil)
        end
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user
    password = get_in(params, ["admin", "password"]) || ""

    case AdminAccess.elevate_with_password(
           user,
           password,
           ConnectionEnv.env(conn),
           UserAuth.request_context(conn)
         ) do
      {:ok, user} ->
        enter(conn, user)

      {:error, :invalid_password} ->
        left = LoginThrottle.remaining(user.email)
        render_prompt(conn, "パスワードが正しくありません。（あと #{left} 回失敗すると一時的にロックされます）")

      {:error, {:locked, until}} ->
        render_prompt(conn, "失敗が続いたため、#{AskDrive.Clock.format(until, "%m/%d %H:%M")} まで受け付けません。")

      {:error, {:unavailable, message}} ->
        render_prompt(conn, "LDAP サーバーで確認できませんでした: #{message}")

      {:error, :not_eligible} ->
        not_eligible(conn)
    end
  end

  @doc "Sign in again (the proof of identity without LDAP), then on to Platform Admin."
  def reauth(conn, _params) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> redirect(to: "/login?" <> URI.encode_query(%{return_to: "/admin/elevate"}))
  end

  @doc """
  Drops administrator rights while keeping the user signed in (F-908).
  """
  def delete(conn, _params) do
    if conn.assigns[:admin_elevated?] do
      AdminAccess.release(conn.assigns.current_user, UserAuth.request_context(conn))
    end

    conn
    |> UserAuth.release_elevation()
    |> put_flash(:info, "管理者権限を解除しました。")
    |> redirect(to: ~p"/")
  end

  defp enter(conn, user) do
    {return_to, conn} = UserAuth.pop_return_to(conn, ~p"/admin")

    return_to =
      if String.starts_with?(return_to, "/admin"), do: return_to, else: ~p"/admin"

    conn
    |> UserAuth.elevate_session(user)
    |> put_flash(
      :info,
      "全体管理に入りました。#{div(AdminAccess.session_seconds(), 60)} 分後に自動で解除されます。"
    )
    |> redirect(to: return_to)
  end

  defp require_platform_admin(conn, _opts) do
    if User.admin_eligible?(conn.assigns.current_user),
      do: conn,
      else: conn |> not_eligible() |> halt()
  end

  defp not_eligible(conn) do
    conn
    |> put_flash(:error, "全体管理は、全体管理者だけが使えます。")
    |> redirect(to: ~p"/")
  end

  defp render_prompt(conn, error) do
    conn
    |> assign(:error_message, error)
    |> assign(:method, AdminAccess.confirmation_method())
    |> assign(:fresh_minutes, AppAdminAccess.fresh_login_minutes())
    |> assign(:page_title, "全体管理へ")
    |> render(:elevate)
  end
end
