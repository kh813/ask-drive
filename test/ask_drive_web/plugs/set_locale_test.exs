defmodule AskDriveWeb.Plugs.SetLocaleTest do
  use AskDriveWeb.ConnCase, async: true

  alias AskDriveWeb.Plugs.SetLocale

  test "defaults to en when no preference, session, or accept-language is present", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> SetLocale.call([])

    assert conn.assigns[:locale] == "en"
    assert get_session(conn, "locale") == "en"
    assert Gettext.get_locale(AskDriveWeb.Gettext) == "en"
  end

  test "detects ja from Accept-Language header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "ja,en-US;q=0.9,en;q=0.8")
      |> init_test_session(%{})
      |> SetLocale.call([])

    assert conn.assigns[:locale] == "ja"
    assert get_session(conn, "locale") == "ja"
    assert Gettext.get_locale(AskDriveWeb.Gettext) == "ja"
  end

  test "detects en from Accept-Language header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "en-US,en;q=0.9")
      |> init_test_session(%{})
      |> SetLocale.call([])

    assert conn.assigns[:locale] == "en"
    assert get_session(conn, "locale") == "en"
  end

  test "prefers session locale over accept-language header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "en-US,en;q=0.9")
      |> init_test_session(%{"locale" => "ja"})
      |> SetLocale.call([])

    assert conn.assigns[:locale] == "ja"
    assert get_session(conn, "locale") == "ja"
  end

  test "prefers query param locale over session", %{conn: conn} do
    conn =
      conn
      |> Map.put(:params, %{"locale" => "ja"})
      |> init_test_session(%{"locale" => "en"})
      |> SetLocale.call([])

    assert conn.assigns[:locale] == "ja"
    assert get_session(conn, "locale") == "ja"
  end

  test "falls back to default for unsupported locale", %{conn: conn} do
    conn =
      conn
      |> Map.put(:params, %{"locale" => "fr"})
      |> init_test_session(%{})
      |> SetLocale.call([])

    assert conn.assigns[:locale] == "en"
  end
end
