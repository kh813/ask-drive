defmodule AskDriveWeb.LocaleControllerTest do
  use AskDriveWeb.ConnCase, async: true

  test "sets valid locale in session and redirects to referer", %{conn: conn} do
    conn =
      conn
      |> put_req_header("referer", "/some-path")
      |> get(~p"/locale/ja")

    assert redirected_to(conn) == "/some-path"
    assert get_session(conn, "locale") == "ja"
  end

  test "falls back to default locale on invalid locale", %{conn: conn} do
    conn = get(conn, ~p"/locale/invalid")

    assert redirected_to(conn) == "/"
    assert get_session(conn, "locale") == "en"
  end
end
