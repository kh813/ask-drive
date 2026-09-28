defmodule AskDriveWeb.AuthController do
  use AskDriveWeb, :controller
  alias AskDrive.Accounts
  alias AskDrive.Drive.OAuth

  def request(conn, params) do
    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    redirect_uri = callback_url(conn)
    authorize_url = OAuth.authorize_url(state, redirect_uri)
    return_to = params["return_to"] || "/"

    conn
    |> put_session(:oauth_state, state)
    |> put_session(:oauth_return_to, return_to)
    |> redirect(external: authorize_url)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    session_state = get_session(conn, :oauth_state)
    return_to = get_session(conn, :oauth_return_to) || "/"

    if session_state && session_state == state do
      redirect_uri = callback_url(conn)

      case OAuth.exchange_code(code, redirect_uri) do
        {:ok, tokens} ->
          setting = AskDrive.Settings.get_setting!()
          email = tokens["email"] || ""
          allowed_domain = setting.allowed_domain

          if allowed_domain && allowed_domain != "" &&
               not String.ends_with?(email, "@" <> allowed_domain) do
            conn
            |> delete_session(:oauth_state)
            |> delete_session(:oauth_return_to)
            |> put_flash(:error, "アクセス拒否: 許可されたドメイン (@#{allowed_domain}) のアカウントのみログイン可能です。")
            |> redirect(to: return_to)
          else
            {:ok, account} = Accounts.save_tokens(tokens)

            conn
            |> delete_session(:oauth_state)
            |> delete_session(:oauth_return_to)
            |> put_flash(:info, "Google アカウント (#{account.email || "Drive"}) と連携しました。")
            |> redirect(to: return_to)
          end

        {:error, reason} ->
          conn
          |> delete_session(:oauth_state)
          |> delete_session(:oauth_return_to)
          |> put_flash(:error, "Google 認証に失敗しました: #{inspect(reason)}")
          |> redirect(to: return_to)
      end
    else
      conn
      |> delete_session(:oauth_state)
      |> delete_session(:oauth_return_to)
      |> put_flash(:error, "不正な認証リクエスト (state 不一致) です。もう一度お試しください。")
      |> redirect(to: return_to)
    end
  end

  def callback(conn, %{"error" => error}) do
    return_to = get_session(conn, :oauth_return_to) || "/"

    conn
    |> delete_session(:oauth_state)
    |> delete_session(:oauth_return_to)
    |> put_flash(:error, "Google 認証がキャンセルまたは失敗しました: #{error}")
    |> redirect(to: return_to)
  end

  def disconnect(conn, params) do
    Accounts.disconnect_account()
    return_to = params["return_to"] || "/"

    conn
    |> put_flash(:info, "Google アカウントの連携を解除しました。")
    |> redirect(to: return_to)
  end

  defp callback_url(conn) do
    url(~p"/auth/google/callback")
  rescue
    _ ->
      port_suffix = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
      "#{conn.scheme}://#{conn.host}#{port_suffix}/auth/google/callback"
  end
end
