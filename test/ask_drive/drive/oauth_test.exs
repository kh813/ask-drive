defmodule AskDrive.Drive.OAuthTest do
  use ExUnit.Case, async: true
  alias AskDrive.Drive.OAuth

  test "authorize_url/2 constructs standard Google OAuth 2.0 authorization URL" do
    state = "random_state_123"
    redirect_uri = "http://localhost:4000/auth/google/callback"

    url = OAuth.authorize_url(state, redirect_uri)
    uri = URI.parse(url)

    assert uri.scheme == "https"
    assert uri.host == "accounts.google.com"
    assert uri.path == "/o/oauth2/v2/auth"

    query = URI.decode_query(uri.query)
    assert query["state"] == state
    assert query["redirect_uri"] == redirect_uri
    assert query["access_type"] == "offline"
    assert query["prompt"] == "consent"
    assert query["response_type"] == "code"
    assert String.contains?(query["scope"], "drive.readonly")
    assert String.contains?(query["scope"], "userinfo.email")
  end
end
