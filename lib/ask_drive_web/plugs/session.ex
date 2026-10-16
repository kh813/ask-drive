defmodule AskDriveWeb.Plugs.Session do
  @moduledoc """
  `Plug.Session` whose cookie is marked `Secure` whenever the browser is on HTTPS (spec
  F-1014): directly, or through a proxy or the API gateway that terminated TLS
  (`AskDriveWeb.Plugs.SSLHeaders` runs first and sets the scheme the browser used). Plain
  HTTP (development, `ASK_DRIVE_SSL=false` on a LAN) keeps a cookie the browser will send.
  """
  @behaviour Plug

  @impl true
  def init(opts),
    do: %{
      http: Plug.Session.init(opts),
      https: Plug.Session.init(Keyword.put(opts, :secure, true))
    }

  @impl true
  def call(conn, %{http: http, https: https}),
    do: Plug.Session.call(conn, if(conn.scheme == :https, do: https, else: http))
end
