defmodule AskDriveWeb.AuthControllerTest do
  use AskDriveWeb.ConnCase
  alias AskDrive.Accounts
  alias AskDrive.Settings

  setup do
    setting = Settings.get_setting!()

    {:ok, setting} =
      Settings.update_setting(setting, %{
        google_client_id: "test-client-id",
        oauth_login_enabled: true
      })

    %{setting: setting}
  end

  test "GET /auth/google redirects to Google OAuth endpoint and stores state in session", %{
    conn: conn
  } do
    conn = get(conn, ~p"/auth/google")
    assert redirected_to(conn) =~ "https://accounts.google.com/o/oauth2/v2/auth"
    assert redirected_to(conn) =~ "openid"
    assert get_session(conn, :oauth_state) != nil
    assert get_session(conn, :oauth_flow) == "login"
  end

  test "redirect_uri reflects the host actually used, not the endpoint's static config", %{
    conn: conn
  } do
    # The admin registers Google OAuth from localhost, but employees reach the box by LAN IP
    # or hostname. If redirect_uri were built from the endpoint's `:url` config (defaulting
    # to "localhost") instead of the request, Google would send everyone's browser back to
    # "localhost" — which resolves to their own machine, not the server.
    conn =
      conn |> Map.put(:host, "192.168.11.42") |> Map.put(:port, 4000) |> get(~p"/auth/google")

    redirect_uri =
      redirected_to(conn)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("redirect_uri")

    assert redirect_uri == "http://192.168.11.42:4000/auth/google/callback"
  end

  test "GET /auth/google/callback with invalid state redirects with error", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{oauth_state: "expected_state"})
      |> get(~p"/auth/google/callback?code=some_code&state=wrong_state")

    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "不正な認証リクエスト"
  end

  test "DELETE /auth/google requires an elevated session", %{conn: conn} do
    conn = delete(conn, ~p"/auth/google")
    assert redirected_to(conn) == ~p"/login"
  end

  test "DELETE /auth/google disconnects account for an elevated administrator", %{conn: conn} do
    Accounts.save_tokens(%{
      email: "test@example.com",
      access_token: "tok",
      refresh_token: "ref",
      expires_in: 3600
    })

    assert Accounts.get_account() != nil

    admin = user_fixture(admin_eligible: true)
    conn = conn |> log_in_admin(admin) |> delete(~p"/auth/google", return_to: "/")

    assert redirected_to(conn) == ~p"/"
    assert Accounts.get_account() == nil
  end
end
