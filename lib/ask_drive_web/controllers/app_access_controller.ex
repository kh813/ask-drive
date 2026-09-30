defmodule AskDriveWeb.AppAccessController do
  @moduledoc """
  Unlocks an app's passphrase (spec F-1112). A plain HTTP POST rather than a LiveView event
  so the unlock can be written to the session: it then holds across reloads and visits for
  30 days, until the passphrase changes.

  Wrong guesses count like password sign-in failures (F-1305), per app *and* connection
  environment: 5 within 5 minutes lock that browser out of that app for 15 minutes, and the
  environment's 24-hour limit applies too. Not per app alone — anyone could then lock an
  app for everyone by guessing wrong on purpose.
  """
  use AskDriveWeb, :controller

  alias AskDrive.{Apps, Settings}
  alias AskDrive.Accounts.{AdminAccess, LoginThrottle}
  alias AskDriveWeb.ConnectionEnv

  def unlock(conn, %{"app" => slug} = params) do
    case Apps.get_by_slug(slug) do
      nil ->
        redirect(conn, to: ~p"/")

      app ->
        if conn.assigns[:current_user] do
          do_unlock(conn, app, get_in(params, ["chat_access", "password"]) || "")
        else
          redirect(conn, to: ~p"/login?#{%{return_to: "/" <> app.slug}}")
        end
    end
  end

  defp do_unlock(conn, app, password) do
    env = ConnectionEnv.env(conn)
    key = throttle_key(app, env)
    setting = Apps.with_app(app, &Settings.get_setting!/0)
    back = "/" <> app.slug

    case LoginThrottle.check(key, env.key) do
      {:locked, until, _scope} ->
        conn
        |> put_flash(
          :error,
          "合言葉の入力ミスが続いたため、#{AskDrive.Clock.format(until, "%m/%d %H:%M")} まで受け付けません。"
        )
        |> redirect(to: back)

      :ok ->
        if AdminAccess.verify_access_password(password, setting) do
          LoginThrottle.clear(key)

          conn
          |> put_session(session_key(app), AdminAccess.access_unlock_token(setting))
          |> put_flash(:info, "アクセス制限を解除しました。")
          |> redirect(to: back)
        else
          LoginThrottle.record_failure(key, env, "access_password")
          left = LoginThrottle.remaining(key)

          conn
          |> put_flash(
            :error,
            "合言葉（アクセスパスワード）が正しくありません。" <>
              if(left > 0, do: "（あと #{left} 回失敗すると一時的にロックされます）", else: "")
          )
          |> redirect(to: back)
        end
    end
  end

  @doc "The session key remembering an unlocked app."
  def session_key(app), do: "unlocked_app_#{app.slug}"

  # counted as an "account" of LoginThrottle: this app, from this environment
  defp throttle_key(app, env), do: "access:#{app.slug}|#{env.key}"
end
