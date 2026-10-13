defmodule AskDriveWeb.AdminGatewayTest do
  @moduledoc "The API gateway section of the HTTPS card (spec F-1014)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{CertHelper, Gateway}

  @secret "s3cret-value-from-infra-0123456789"

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    Application.put_env(:ask_drive, :ssl_dir, CertHelper.tmp_dir())

    on_exit(fn ->
      System.delete_env("ASK_DRIVE_DISABLE_AUTH")
      Application.put_env(:ask_drive, :ssl_dir, nil)
      :persistent_term.erase({Gateway, :cache})
    end)

    :ok
  end

  test "turned on from the server itself; the secret is never shown", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin?tab=settings")
    assert has_element?(view, "#gateway-form")
    assert has_element?(view, "#gateway-state", "無効")

    view
    |> form("#gateway-form", %{
      "gateway" => %{"secret" => @secret, "public_url" => "https://app.example.com"}
    })
    |> render_submit()

    assert Gateway.enabled?()
    assert Gateway.settings().public_url == "https://app.example.com"
    refute render(view) =~ @secret
  end

  test "invalid settings are refused with the reason", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin?tab=settings")

    html =
      view
      |> form("#gateway-form", %{
        "gateway" => %{"secret" => "short", "public_url" => "https://app.example.com"}
      })
      |> render_submit()

    assert html =~ "16 文字以上"
    refute Gateway.enabled?()
  end
end
