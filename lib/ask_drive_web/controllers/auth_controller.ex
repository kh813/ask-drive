defmodule AskDriveWeb.AuthController do
  use AskDriveWeb, :controller
  alias AskDrive.Accounts
  alias AskDrive.Drive.OAuth

  def request(conn, _params) do
    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    redirect_uri = callback_url(conn)
    authorize_url = OAuth.authorize_url(state, redirect_uri)

    conn
    |> put_session(:oauth_state, state)
    |> redirect(external: authorize_url)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    session_state = get_session(conn, :oauth_state)

    if session_state && session_state == state do
      redirect_uri = callback_url(conn)

      case OAuth.exchange_code(code, redirect_uri) do
        {:ok, tokens} ->
          {:ok, account} = Accounts.save_tokens(tokens)

          conn
          |> delete_session(:oauth_state)
          |> put_flash(:info, "Google アカウント (#{account.email || "Drive"}) と連携しました。")
          |> redirect(to: ~p"/")

        {:error, reason} ->
          conn
          |> delete_session(:oauth_state)
          |> put_flash(:error, "Google 認証に失敗しました: #{inspect(reason)}")
          |> redirect(to: ~p"/")
      end
    else
      conn
      |> delete_session(:oauth_state)
      |> put_flash(:error, "不正な認証リクエスト (state 不一致) です。もう一度お試しください。")
      |> redirect(to: ~p"/")
    end
  end

  def callback(conn, %{"error" => error}) do
    conn
    |> delete_session(:oauth_state)
    |> put_flash(:error, "Google 認証がキャンセルまたは失敗しました: #{error}")
    |> redirect(to: ~p"/")
  end

  def disconnect(conn, _params) do
    Accounts.disconnect_account()

    conn
    |> put_flash(:info, "Google アカウントの連携を解除しました。")
    |> redirect(to: ~p"/")
  end

  defp callback_url(conn) do
    url(~p"/auth/google/callback")
  rescue
    _ ->
      port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
      "#{conn.scheme}://#{conn.host}#{port_suffix}/auth/google/callback"
  end
end
