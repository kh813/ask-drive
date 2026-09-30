defmodule AskDriveWeb.AdminClientCertsTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{CertHelper, ClientCerts}

  setup %{conn: conn} do
    Application.put_env(:ask_drive, :ssl_dir, CertHelper.tmp_dir())
    Application.put_env(:ask_drive, :restart_endpoint_on_install, false)

    on_exit(fn ->
      Application.put_env(:ask_drive, :ssl_dir, nil)
      Application.delete_env(:ask_drive, :restart_endpoint_on_install)
    end)

    admin = user_fixture(admin_eligible: true)
    %{conn: log_in_admin(conn, admin)}
  end

  test "add a group, issue a certificate (name, expiry, password), download per OS and again, revoke it",
       %{
         conn: conn
       } do
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    assert has_element?(view, "#client-cert-mode", "無効")

    view |> form("#new-cert-group-form", %{"name" => "経理部"}) |> render_submit()
    group = Enum.find(ClientCerts.list_groups(), &(&1.name == "経理部"))
    assert has_element?(view, "#cert-group-#{group.id}", "経理部")

    # a bad password is refused with the reason, nothing issued
    view
    |> form("#issue-cert-form-#{group.id}", %{"password" => "short"})
    |> render_submit()

    assert render(view) =~ "パスワードは 8〜64 文字"
    assert Enum.find(ClientCerts.list_groups(), &(&1.name == "経理部")).certs == []

    expires = Date.add(AskDrive.Clock.local_today(), 90)

    view
    |> form("#issue-cert-form-#{group.id}", %{
      "label" => "受付の PC",
      "expires_on" => Date.to_iso8601(expires),
      "password" => "Uketsuke-2026"
    })
    |> render_submit()

    assert has_element?(view, "#issued-cert-password", "Uketsuke-2026")
    assert has_element?(view, "#issued-cert", "AskDrive（経理部 / 受付の PC）")
    assert has_element?(view, "#issued-cert", Date.to_iso8601(expires))

    href = fn format ->
      view
      |> element("#issued-cert-download-#{format}")
      |> render()
      |> then(&Regex.run(~r{href="([^"]+)"}, &1))
      |> List.last()
      |> String.replace("&amp;", "&")
    end

    resp = get(conn, href.("windows"))
    assert resp.status == 200
    assert Plug.Conn.get_resp_header(resp, "content-type") |> hd() =~ "application/x-pkcs12"
    assert Plug.Conn.get_resp_header(resp, "content-disposition") |> hd() =~ ".pfx"
    assert byte_size(resp.resp_body) > 1000

    # another form for another device, within the 10 minutes
    resp = get(conn, href.("ios"))
    assert Plug.Conn.get_resp_header(resp, "content-disposition") |> hd() =~ ".mobileconfig"
    assert resp.resp_body =~ "com.apple.security.pkcs12"

    [cert] = Enum.find(ClientCerts.list_groups(), &(&1.name == "経理部")).certs
    assert has_element?(view, "#client-cert-#{cert.id}", "受付の PC")

    # downloaded again later: the same certificate and password (F-1409)
    first = get(conn, href.("macos")).resp_body
    view |> element("#redownload-cert-#{cert.id}") |> render_click()
    assert has_element?(view, "#issued-cert", "ダウンロードできます")
    assert has_element?(view, "#issued-cert-password", "Uketsuke-2026")
    assert get(conn, href.("macos")).resp_body == first

    view |> element("#revoke-cert-#{cert.id}") |> render_click()
    assert has_element?(view, "#client-cert-#{cert.id}", "失効")
    refute has_element?(view, "#redownload-cert-#{cert.id}")
  end

  test "the office LAN is set on the screen", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    view |> form("#client-cert-lan-form", %{"lan" => "192.168.0.0/16, nope"}) |> render_submit()
    assert render(view) =~ "IP アドレス・範囲として読み取れません: nope"

    view
    |> form("#client-cert-lan-form", %{"lan" => "192.168.0.0/16, 10.0.0.0/8"})
    |> render_submit()

    assert ClientCerts.lan_ranges() == ["192.168.0.0/16", "10.0.0.0/8"]
    assert has_element?(view, ~s(#client-cert-lan-form input[value="192.168.0.0/16, 10.0.0.0/8"]))
  end

  test "modes from the screen: monitor, then enforce (allowed from the server itself)", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    view |> element("#client-cert-mode-monitor") |> render_click()
    assert ClientCerts.mode() == "monitor"
    assert has_element?(view, "#client-cert-mode", "監視")

    # the test connection is local, the way back in: enforce is allowed
    view |> element("#client-cert-mode-enforce") |> render_click()
    assert ClientCerts.mode() == "enforce"

    view |> element("#client-cert-mode-off") |> render_click()
    assert ClientCerts.mode() == "off"
  end
end
