defmodule AskDriveWeb.ConnectionEnv do
  @moduledoc """
  The connection environment of a request (spec F-1305), for the lockout of password
  sign-in and of the per-app passphrase: the browser's device cookie (a random id set on
  the login page and the passphrase page), or — for a client without it — the source
  address with its User-Agent and Accept-Language.
  """
  import Plug.Conn
  alias AskDrive.Accounts.LoginThrottle

  @device_cookie "_askdrive_device"
  @device_cookie_opts [sign: true, max_age: 400 * 86_400, http_only: true, same_site: "Lax"]

  @doc "Gives the browser a device cookie unless it has one."
  def ensure_device_cookie(conn) do
    conn = fetch_cookies(conn, signed: [@device_cookie])

    if conn.cookies[@device_cookie] do
      conn
    else
      id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
      put_resp_cookie(conn, @device_cookie, id, @device_cookie_opts)
    end
  end

  @doc "`%{key:, ip:, user_agent:}` for LoginThrottle."
  def env(conn) do
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
end
