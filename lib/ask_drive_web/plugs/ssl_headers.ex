defmodule AskDriveWeb.Plugs.SSLHeaders do
  @moduledoc """
  The entrance of every request (spec 6.10, F-1013):

    * from a **trusted reverse proxy** (the TCP peer is in `AskDrive.Network`'s list), take
      the scheme, host and port from X-Forwarded-Proto/Host/Port and the client's address
      from CF-Connecting-IP / X-Forwarded-For, so generated URLs are the public ones and the
      lockout and logs see the real client. From anyone else these headers are ignored —
      they would let a client spoof its address or the scheme;
    * **plain HTTP** is redirected to HTTPS while HTTPS is on, unless it came from a
      trusted proxy (which terminated TLS itself);
    * **HSTS** only when an administrator's own certificate is installed. With the
      self-signed one it would stop browsers from letting users past the warning.
  """
  @behaviour Plug
  import Plug.Conn
  alias AskDrive.Network

  @hsts "max-age=31536000"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    trusted? = Network.trusted?(conn.remote_ip)

    cond do
      conn.scheme == :http and AskDrive.SSL.enabled?() and not trusted? ->
        AskDriveWeb.HTTPSRedirect.call(conn, [])

      true ->
        conn = if trusted?, do: from_proxy(conn), else: conn

        if conn.scheme == :https and AskDrive.SSL.hsts?(),
          do: put_resp_header(conn, "strict-transport-security", @hsts),
          else: conn
    end
  end

  defp from_proxy(conn) do
    conn =
      Plug.RewriteOn.call(
        conn,
        Plug.RewriteOn.init([:x_forwarded_proto, :x_forwarded_host, :x_forwarded_port])
      )

    client =
      Network.client_ip(
        conn |> get_req_header("cf-connecting-ip") |> List.first(),
        conn |> get_req_header("x-forwarded-for") |> Enum.join(",")
      )

    if client, do: %{conn | remote_ip: client}, else: conn
  end
end
