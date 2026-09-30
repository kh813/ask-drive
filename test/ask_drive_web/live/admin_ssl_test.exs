defmodule AskDriveWeb.AdminSSLTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{CertHelper, SSL}

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    dir = CertHelper.tmp_dir()
    endpoint = Application.get_env(:ask_drive, AskDriveWeb.Endpoint)
    Application.put_env(:ask_drive, :ssl_dir, dir)
    Application.put_env(:ask_drive, :ssl_enabled, true)
    Application.put_env(:ask_drive, :restart_endpoint_on_install, false)
    SSL.configure_endpoint!()

    on_exit(fn ->
      System.delete_env("ASK_DRIVE_DISABLE_AUTH")
      Application.put_env(:ask_drive, :ssl_dir, nil)
      Application.put_env(:ask_drive, :ssl_enabled, false)
      Application.delete_env(:ask_drive, :restart_endpoint_on_install)
      Application.put_env(:ask_drive, AskDriveWeb.Endpoint, endpoint)
      :persistent_term.erase({SSL, :meta})
    end)

    :ok
  end

  # with HTTPS on, plain HTTP is redirected to it (spec F-1013): come in over HTTPS
  @settings "https://www.example.com:4443/admin?tab=settings"

  defp upload(view, name, filename, content) do
    view
    |> file_input("#ssl-upload-form", name, [
      %{name: filename, content: content, type: "application/x-pem-file"}
    ])
    |> render_upload(filename)
  end

  test "shows the self-signed certificate, validates an upload, then applies it", %{conn: conn} do
    {:ok, view, html} = live(conn, @settings)
    assert html =~ "HTTPS（SSL 証明書）"
    assert html =~ "自己署名証明書"

    pem = CertHelper.ca_signed(["askdrive.example.com"])
    upload(view, :ssl_cert, "server.crt", pem.cert)
    upload(view, :ssl_key, "server.key", pem.key)
    upload(view, :ssl_chain, "chain.pem", pem.chain)

    html =
      view
      |> form("#ssl-upload-form", %{"ssl_hostname" => "askdrive.example.com"})
      |> render_submit()

    assert html =~ "検証に成功しました"
    assert has_element?(view, "#apply-ssl-btn")

    view |> element("#apply-ssl-btn") |> render_click()
    Process.sleep(1_000)
    assert %{"source" => "custom", "names" => ["askdrive.example.com"]} = SSL.current()
  end

  test "a failed validation lists the problems and offers no apply button", %{conn: conn} do
    {:ok, view, _html} = live(conn, @settings)
    a = CertHelper.ca_signed(["a.example.com"])
    b = CertHelper.ca_signed(["b.example.com"])

    upload(view, :ssl_cert, "a.crt", a.cert)
    upload(view, :ssl_key, "b.key", b.key)

    html = view |> form("#ssl-upload-form", %{"ssl_hostname" => ""}) |> render_submit()
    assert html =~ "検証に失敗しました"
    assert html =~ "対になっていません"
    refute has_element?(view, "#apply-ssl-btn")
    assert %{"source" => "self_signed"} = SSL.current()
  end
end
