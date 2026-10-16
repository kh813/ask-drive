defmodule AskDriveWeb.HTTPSRedirectTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias AskDriveWeb.HTTPSRedirect

  test "GET is redirected with 301 to the same host, path and query on the HTTPS port" do
    conn = conn(:get, "http://askdrive.local:4080/admin?tab=settings") |> HTTPSRedirect.call([])
    assert conn.status == 301

    assert Plug.Conn.get_resp_header(conn, "location") == [
             "https://askdrive.local:4443/admin?tab=settings"
           ]

    assert conn.halted
  end

  test "other methods get 308 so the method and body are kept" do
    conn = conn(:post, "http://askdrive.local:4000/logout") |> HTTPSRedirect.call([])
    assert conn.status == 308
    assert Plug.Conn.get_resp_header(conn, "location") == ["https://askdrive.local:4443/logout"]
  end
end
