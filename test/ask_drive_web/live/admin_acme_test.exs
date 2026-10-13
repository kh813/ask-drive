defmodule AskDriveWeb.AdminAcmeTest do
  @moduledoc "The Let's Encrypt section of the HTTPS card (spec F-1009 – F-1012)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{CertHelper, Settings, SSL, StubValueDomain}

  @settings "https://www.example.com:4443/admin?tab=settings"

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    endpoint = Application.get_env(:ask_drive, AskDriveWeb.Endpoint)
    {server, url} = StubValueDomain.start!(self())
    StubValueDomain.set(:records, "a @ 192.0.2.1\na ask 10.0.0.5")

    env = [
      ssl_dir: CertHelper.tmp_dir(),
      ssl_enabled: true,
      restart_endpoint_on_install: false,
      valuedomain_base_url: url
    ]

    for {k, v} <- env, do: Application.put_env(:ask_drive, k, v)
    SSL.configure_endpoint!()

    on_exit(fn ->
      Process.exit(server, :normal)
      System.delete_env("ASK_DRIVE_DISABLE_AUTH")
      for {k, _} <- env, do: Application.delete_env(:ask_drive, k)
      Application.put_env(:ask_drive, AskDriveWeb.Endpoint, endpoint)
      :persistent_term.erase({SSL, :meta})
    end)

    :ok
  end

  test "settings are saved; the API key is kept and never shown", %{conn: conn} do
    {:ok, view, _html} = live(conn, @settings)
    assert has_element?(view, "#acme-settings #acme-form")
    # nothing to run until it is set up
    assert has_element?(view, "#run-acme-btn[disabled]")
    assert has_element?(view, "#test-acme-dns-btn[disabled]")

    view
    |> form("#acme-form", %{
      "acme" => %{
        "acme_enabled" => "true",
        "acme_hostname" => "ask.example.com",
        "acme_dns_zone" => "example.com",
        "valuedomain_api_key" => "secret-vd-key",
        "acme_staging" => "true"
      }
    })
    |> render_submit()

    setting = Settings.get_setting!()
    assert setting.acme_enabled
    assert setting.acme_staging
    assert setting.valuedomain_api_key == "secret-vd-key"

    refute render(view) =~ "secret-vd-key"
    refute has_element?(view, "#run-acme-btn[disabled]")

    # the DNS test reads the zone and changes nothing
    view |> element("#test-acme-dns-btn") |> render_click()
    assert render_async(view) =~ "レコード 2 件を確認"
    assert_received {:stub_vd, "GET", "example.com", _, "Bearer secret-vd-key"}
    refute_received {:stub_vd, "PUT", _, _, _}
  end

  test "a host outside the zone is refused with the reason", %{conn: conn} do
    {:ok, view, _html} = live(conn, @settings)

    html =
      view
      |> form("#acme-form", %{
        "acme" => %{
          "acme_enabled" => "true",
          "acme_hostname" => "ask.other.org",
          "acme_dns_zone" => "example.com",
          "valuedomain_api_key" => "k"
        }
      })
      |> render_submit()

    assert html =~ "サブドメインにしてください"
    refute Settings.get_setting!().acme_enabled
  end
end
