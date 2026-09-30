defmodule AskDriveWeb.AdminNetworkTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{CertHelper, Network}

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    Application.put_env(:ask_drive, :ssl_dir, CertHelper.tmp_dir())
    Application.put_env(:ask_drive, :restart_endpoint_on_install, false)

    on_exit(fn ->
      System.delete_env("ASK_DRIVE_DISABLE_AUTH")
      Application.put_env(:ask_drive, :ssl_dir, nil)
      Application.delete_env(:ask_drive, :restart_endpoint_on_install)
      :persistent_term.erase({Network, :last_result})
    end)
  end

  test "trusted proxies are saved at once; a port change is applied with a restart", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    assert has_element?(view, "#network-settings", "ポートとリバースプロキシ")
    assert has_element?(view, ~s(#network-form input[name="network[https_port]"][value="4443"]))

    view
    |> form("#network-form", %{"network" => %{"trusted_proxies" => "127.0.0.1, bogus"}})
    |> render_submit()

    assert render(view) =~ "プロキシの IP として読み取れません: bogus"
    assert Network.trusted_proxies() == []

    view
    |> form("#network-form", %{"network" => %{"trusted_proxies" => "127.0.0.1, 10.0.0.0/24"}})
    |> render_submit()

    assert render(view) =~ "すぐに反映されます"
    assert Network.trusted_proxies() == ["127.0.0.1", "10.0.0.0/24"]

    view |> form("#network-form", %{"network" => %{"https_port" => "45444"}}) |> render_submit()
    assert render(view) =~ "https://&lt;ホスト&gt;:45444/admin"
    # applied a moment later, off the LiveView process
    Process.sleep(1_000)
    assert Network.https_port() == 45_444
  end
end
