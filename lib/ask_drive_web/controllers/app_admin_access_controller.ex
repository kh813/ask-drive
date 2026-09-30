defmodule AskDriveWeb.AppAdminAccessController do
  @moduledoc """
  Elevation to an app's admin screen with the app's own password (spec F-1113): only for
  the app's assigned administrators. While the password is unset, the first of them to
  arrive sets it here. Elevation is remembered per app in the session.
  """
  use AskDriveWeb, :controller

  plug :put_view, html: AskDriveWeb.AdminAccessHTML

  alias AskDrive.Accounts
  alias AskDrive.Accounts.{AdminAccess, AppAdminAccess}
  alias AskDrive.Apps

  plug :load_app

  def new(conn, _params), do: render_prompt(conn, nil)

  def create(conn, params) do
    app = conn.assigns.app
    password = get_in(params, ["admin", "password"]) || ""

    case AppAdminAccess.elevate(conn.assigns.current_user, app, password, context(conn)) do
      {:ok, token} ->
        conn
        |> put_token(app, token)
        |> put_flash(:info, "窓口「#{app.name}」の管理画面に入りました。")
        |> redirect(to: back_to(conn, app))

      {:error, :invalid_password} ->
        left = AppAdminAccess.attempts_remaining(conn.assigns.current_user, app)
        render_prompt(conn, "パスワードが正しくありません。（あと #{left} 回失敗すると一時的にロックされます）")

      {:error, {:locked_out, until}} ->
        render_prompt(conn, "失敗が続いたため、#{AskDrive.Clock.format(until, "%H:%M")} まで受け付けません。")

      {:error, :no_password} ->
        render_prompt(conn, nil)

      {:error, :not_assigned} ->
        not_assigned(conn, app)
    end
  end

  def set_initial(conn, params) do
    app = conn.assigns.app
    user = conn.assigns.current_user
    password = get_in(params, ["admin", "password"]) || ""
    confirmation = get_in(params, ["admin", "confirmation"]) || ""

    result =
      if password != confirmation,
        do: {:error, :mismatch},
        else: AppAdminAccess.set_initial(user, app, password, context(conn))

    case result do
      :ok ->
        {:ok, token} = AppAdminAccess.elevate(user, app, password, context(conn))

        conn
        |> put_token(app, token)
        |> put_flash(:info, "窓口「#{app.name}」の管理者パスワードを設定しました。")
        |> redirect(to: back_to(conn, app))

      {:error, :mismatch} ->
        render_prompt(conn, "確認のパスワードが一致しません。")

      {:error, :too_short} ->
        render_prompt(conn, "パスワードは #{AdminAccess.min_password_length()} 文字以上にしてください。")

      {:error, :surrounding_whitespace} ->
        render_prompt(conn, "パスワードの前後に空白は使えません。")

      {:error, :already_set} ->
        render_prompt(conn, "パスワードはすでに設定されています。")

      {:error, :not_assigned} ->
        not_assigned(conn, app)
    end
  end

  def release(conn, _params) do
    app = conn.assigns.app
    tokens = get_session(conn, AppAdminAccess.session_key()) || %{}

    conn
    |> put_session(AppAdminAccess.session_key(), Map.delete(tokens, app.slug))
    |> put_flash(:info, "窓口「#{app.name}」の管理画面から出ました。")
    |> redirect(to: "/" <> app.slug)
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
      "窓口「#{app.name}」の管理画面は、この窓口の担当者（窓口管理者）だけが使えます。担当者の割り当ては全体管理者に依頼してください。"
    )
    |> redirect(to: "/" <> app.slug)
  end

  defp render_prompt(conn, error) do
    app = conn.assigns.app
    setting = AppAdminAccess.setting(app)

    conn
    |> assign(:error_message, error)
    |> assign(:password_set?, is_binary(setting.app_admin_password_hash))
    |> assign(:reset_at, setting.app_admin_password_reset_at)
    |> assign(:reset_by, setting.app_admin_password_reset_by)
    |> assign(:min_length, AdminAccess.min_password_length())
    |> assign(:page_title, "#{app.name} の管理画面へ")
    |> render(:app_elevate)
  end

  defp put_token(conn, app, token) do
    tokens = get_session(conn, AppAdminAccess.session_key()) || %{}
    put_session(conn, AppAdminAccess.session_key(), Map.put(tokens, app.slug, token))
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
