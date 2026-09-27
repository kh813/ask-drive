defmodule AskDriveWeb.PageControllerTest do
  use AskDriveWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "AskDrive"
  end
end
