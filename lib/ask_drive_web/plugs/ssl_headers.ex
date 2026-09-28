defmodule AskDriveWeb.Plugs.SSLHeaders do
  @moduledoc """
  HTTPS-related request/response handling in the endpoint (spec 6.10):

    * behind a reverse proxy that terminates TLS (`ASK_DRIVE_TRUST_FORWARDED=true`), take the
      scheme, host and port from X-Forwarded-Proto/Host/Port, so generated URLs — the Google
      OAuth redirect_uri in particular — are the public ones. Off by default: trusting these
      headers from arbitrary clients would let them spoof the scheme.
    * send HSTS only when an administrator's own certificate is installed. With the
      self-signed one, HSTS would stop browsers from letting users past the certificate
      warning, locking them out.
  """
  @behaviour Plug
  import Plug.Conn

  @hsts "max-age=31536000"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = if trust_forwarded?(), do: rewrite_forwarded(conn), else: conn

    if conn.scheme == :https and AskDrive.SSL.hsts?(),
      do: put_resp_header(conn, "strict-transport-security", @hsts),
      else: conn
  end

  defp trust_forwarded?, do: Application.get_env(:ask_drive, :trust_forwarded, false)

  defp rewrite_forwarded(conn) do
    Plug.RewriteOn.call(
      conn,
      Plug.RewriteOn.init([:x_forwarded_proto, :x_forwarded_host, :x_forwarded_port])
    )
  end
end
