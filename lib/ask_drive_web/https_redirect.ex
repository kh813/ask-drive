defmodule AskDriveWeb.HTTPSRedirect do
  @moduledoc """
  The only thing the HTTP ports do when HTTPS is on (spec 6.10): redirect every request to
  the same host, path and query on the HTTPS port. Plug.SSL's redirect drops the port (it
  assumes 443), which is wrong for 4443, hence this small plug.

  GET/HEAD get 301 (cacheable); other methods 308, which keeps the method and body.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    port = AskDrive.SSL.https_port()
    port_suffix = if port == 443, do: "", else: ":#{port}"
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    location = "https://#{conn.host}#{port_suffix}#{conn.request_path}#{query}"
    status = if conn.method in ["GET", "HEAD"], do: 301, else: 308

    conn
    |> put_resp_header("location", location)
    |> send_resp(status, "")
    |> halt()
  end
end
