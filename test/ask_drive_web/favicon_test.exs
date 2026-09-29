defmodule AskDriveWeb.FaviconTest do
  use AskDriveWeb.ConnCase, async: false

  test "the app icon is served as favicon (svg, ico) and apple-touch-icon", %{conn: conn} do
    assert %{status: 200} = svg = get(conn, "/favicon.svg")
    assert svg.resp_body =~ "#4f46e5"
    assert %{status: 200} = get(build_conn(), "/favicon.ico")
    assert %{status: 200} = get(build_conn(), "/apple-touch-icon.png")
  end

  test "pages link the icons", %{conn: conn} do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)

    html = conn |> get("/it-support") |> html_response(200)
    assert html =~ ~s(rel="icon" href="/favicon.svg")
    assert html =~ ~s(rel="apple-touch-icon" href="/apple-touch-icon.png")
  end
end
