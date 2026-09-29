defmodule AskDriveWeb.AdminAccessController do
  @moduledoc """
  The elevation prompt: `sudo` for AskDrive (spec 6.9).

  A controller rather than a LiveView because elevating has to write to the session, which
  a LiveView cannot do.
  """
  use AskDriveWeb, :controller

  alias AskDrive.Accounts.AdminAccess
  alias AskDriveWeb.UserAuth

  @doc """
  Shows the password prompt, or the first-run password setup when none is configured yet.
  """
  def new(conn, _params) do
    render_prompt(conn)
  end

  @doc """
  Verifies the administrator password and elevates the session.
  """
  def create(conn, %{"admin" => %{"password" => password}}) do
    user = conn.assigns.current_user
    context = UserAuth.request_context(conn)

    case AdminAccess.elevate(user, password, context) do
      {:ok, user} ->
        {return_to, conn} = UserAuth.pop_return_to(conn, ~p"/admin")

        conn
        |> UserAuth.elevate_session(user)
        |> put_flash(:info, "管理者権限に昇格しました。#{minutes(conn)} 分後に自動で解除されます。")
        |> redirect(to: return_to)

      {:error, :no_password} ->
        render_prompt(conn, error: "管理者パスワードが未設定です。まず初回パスワードを設定してください。")

      {:error, {:locked_out, unlock_at}} ->
        render_prompt(conn,
          error: "試行回数の上限に達しました。#{Calendar.strftime(unlock_at, "%H:%M")} 以降に再度お試しください。"
        )

      {:error, :invalid_password} ->
        remaining = AdminAccess.attempts_remaining(user)

        render_prompt(conn,
          error: "管理者パスワードが違います。（残り #{remaining} 回で一時ロックされます）"
        )
    end
  end

  def create(conn, _params), do: render_prompt(conn, error: "パスワードを入力してください。")

  @doc """
  Sets the very first administrator password (F-917).
  """
  def set_password(conn, %{"admin" => %{"password" => password, "confirmation" => confirmation}}) do
    user = conn.assigns.current_user

    cond do
      password != confirmation ->
        render_prompt(conn, error: "パスワードが一致しません。")

      true ->
        case AdminAccess.set_initial_password(user, password, UserAuth.request_context(conn)) do
          {:ok, _setting} ->
            conn
            |> put_flash(:info, "管理者パスワードを設定しました。このパスワードで昇格してください。")
            |> redirect(to: ~p"/admin/elevate")

          {:error, :too_short} ->
            render_prompt(conn,
              error: "パスワードは #{AdminAccess.min_password_length()} 文字以上にしてください。"
            )

          {:error, :surrounding_whitespace} ->
            render_prompt(conn, error: "パスワードの前後に空白を含めないでください。")

          {:error, :already_set} ->
            conn
            |> put_flash(:error, "管理者パスワードは既に設定されています。")
            |> redirect(to: ~p"/admin/elevate")

          {:error, :not_eligible} ->
            conn
            |> put_flash(:error, "このアカウントは管理者パスワードを設定できません。")
            |> redirect(to: ~p"/")
        end
    end
  end

  def set_password(conn, _params), do: render_prompt(conn, error: "パスワードを入力してください。")

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

  defp render_prompt(conn, opts \\ []) do
    if conn.assigns[:admin_elevated?] do
      redirect(conn, to: ~p"/admin")
    else
      user = conn.assigns.current_user

      conn
      |> assign(:password_set?, AdminAccess.password_set?())
      |> assign(:locked_until, AdminAccess.locked_out_until(user))
      |> assign(:attempts_remaining, AdminAccess.attempts_remaining(user))
      |> assign(:min_length, AdminAccess.min_password_length())
      |> assign(:error_message, Keyword.get(opts, :error))
      |> assign(:page_title, "AskDrive - 管理者権限への昇格")
      |> render(:elevate)
    end
  end

  defp minutes(_conn), do: div(AdminAccess.session_seconds(), 60)
end
