defmodule AskDriveWeb.AuthControllerTest do
  use AskDriveWeb.ConnCase
  alias AskDrive.Accounts

  test "GET /auth/google redirects to Google OAuth endpoint and stores state in session", %{
    conn: conn
  } do
    conn = get(conn, ~p"/auth/google")
    assert redirected_to(conn) =~ "https://accounts.google.com/o/oauth2/v2/auth"
    assert get_session(conn, :oauth_state) != nil
  end

  test "GET /auth/google/callback with invalid state redirects with error", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{oauth_state: "expected_state"})
      |> get(~p"/auth/google/callback?code=some_code&state=wrong_state")

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "不正な認証リクエスト"
  end

  test "DELETE /auth/google disconnects account", %{conn: conn} do
    Accounts.save_tokens(%{
      email: "test@example.com",
      access_token: "tok",
      refresh_token: "ref",
      expires_in: 3600
    })

    assert Accounts.get_account() != nil

    conn = delete(conn, ~p"/auth/google")
    assert redirected_to(conn) == ~p"/"
    assert Accounts.get_account() == nil
  end
end
