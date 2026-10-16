defmodule AskDriveWeb.Plugs.GatewayGate do
  @moduledoc """
  Refuses requests that went around the API gateway (spec F-1014). Called from
  `AskDriveWeb.Endpoint.call/2` before anything else — the LiveView socket (`/live`, its
  WebSocket and long-poll) is dispatched before the endpoint's plugs, so a plug there would
  let the socket through.

  With no secret set this does nothing. Otherwise a request passes when it carries the
  gateway's secret header (and is marked `conn.private.askdrive_gateway`, which
  `AskDriveWeb.Plugs.SSLHeaders` uses to believe its forwarded headers), or comes from the
  server itself or a range allowed to connect directly; anything else gets 403.
  """
  import Plug.Conn
  alias AskDrive.Gateway

  def init(opts), do: opts

  def call(conn, _opts) do
    if Gateway.enabled?() do
      gate(conn)
    else
      conn
    end
  end

  defp gate(conn) do
    cond do
      conn |> get_req_header(Gateway.header()) |> List.first() |> Gateway.valid_secret?() ->
        put_private(conn, :askdrive_gateway, true)

      Gateway.direct_allowed?(conn.remote_ip) ->
        conn

      true ->
        refuse(conn)
    end
  end

  defp refuse(conn) do
    url = Gateway.settings().public_url

    link =
      if url,
        do:
          ~s(<p><a href="#{Plug.HTML.html_escape(url)}/">#{Plug.HTML.html_escape(url)}/</a> から開いてください。</p>),
        else: ""

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(403, """
    <!doctype html>
    <html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>AskDrive</title></head>
    <body style="font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem; color: #27272a;">
    <h1 style="font-size: 1.25rem;">このアドレスからは利用できません</h1>
    <p>AskDrive には、社内の入口（Google アカウントでのログイン）を通って接続してください。</p>
    #{link}
    </body></html>
    """)
    |> halt()
  end
end
