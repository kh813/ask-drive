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
    # plain (undigested) paths: prod digests ~p paths to favicon-<hash>.svg, which
    # Plug.Static's `only` list doesn't serve
    assert html =~ ~s(rel="icon" href="/favicon.svg?v=2")
    assert html =~ ~s(rel="apple-touch-icon" href="/apple-touch-icon.png?v=2")
    refute html =~ ~r/favicon-[0-9a-f]{32}/

    # every file the page links is one Plug.Static is allowed to serve
    for path <- ["favicon.svg", "favicon.ico", "apple-touch-icon.png"],
        do: assert(path in AskDriveWeb.static_paths())
  end
end
