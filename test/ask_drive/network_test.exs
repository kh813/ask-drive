defmodule AskDrive.NetworkTest do
  use AskDrive.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias AskDrive.{CertHelper, Network}

  setup do
    dir = CertHelper.tmp_dir()
    Application.put_env(:ask_drive, :ssl_dir, dir)
    Application.put_env(:ask_drive, :restart_endpoint_on_install, false)

    on_exit(fn ->
      Application.put_env(:ask_drive, :ssl_dir, nil)
      Application.put_env(:ask_drive, :ssl_enabled, false)
      Application.delete_env(:ask_drive, :restart_endpoint_on_install)
      :persistent_term.erase({Network, :last_result})
    end)

    %{dir: dir}
  end

  describe "trusted proxies" do
    test "addresses and ranges, IPv4 and IPv6; an IPv4 client seen on an IPv6 listener" do
      {:ok, _, :applied} =
        Network.update(%{"trusted_proxies" => "127.0.0.1, 10.1.0.0/16  fd00::/8"})

      assert Network.trusted?({127, 0, 0, 1})
      assert Network.trusted?({10, 1, 200, 3})
      refute Network.trusted?({10, 2, 0, 1})
      assert Network.trusted?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
      # ::ffff:10.1.2.3
      assert Network.trusted?({0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203})
      refute Network.trusted?(nil)
    end

    test "the client's address: CF-Connecting-IP, else the nearest untrusted X-Forwarded-For" do
      {:ok, _, :applied} = Network.update(%{"trusted_proxies" => "127.0.0.1, 10.0.0.2"})
      assert Network.client_ip("203.0.113.9", "1.1.1.1") == {203, 0, 113, 9}
      # client, then an inner proxy (trusted) appended its own hop
      assert Network.client_ip(nil, "198.51.100.7, 10.0.0.2") == {198, 51, 100, 7}
      assert Network.client_ip(nil, "garbage") == nil
    end

    test "invalid entries are refused" do
      assert {:error, [msg]} =
               Network.update(%{"trusted_proxies" => "10.0.0.1, not-an-ip, 10.0.0.0/99"})

      assert msg =~ "not-an-ip"
      assert msg =~ "10.0.0.0/99"
    end
  end

  describe "ports" do
    test "defaults are HTTP 4000 / HTTPS 4443 unless set" do
      assert Network.https_port() == 4443
      assert is_integer(Network.http_port())
    end

    test "validation: range, the same port twice, a port already in use" do
      assert {:error, [msg]} = Network.validate(%{"http_port" => "70000"})
      assert msg =~ "HTTP のポート"
      assert {:error, [msg]} = Network.validate(%{"http_port" => "5000", "https_port" => "5000"})
      assert msg =~ "同じポート"

      {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {0, 0, 0, 0}])
      {:ok, busy} = :inet.port(socket)
      assert {:error, [msg]} = Network.validate(%{"https_port" => to_string(busy)})
      assert msg =~ "#{busy} は、ほかのプログラムが使用中"
      :gen_tcp.close(socket)
    end

    test "a port change restarts the endpoint and is saved to listen.json", %{dir: dir} do
      assert {:ok, %{https_port: 45_443}, :restarted} = Network.update(%{"https_port" => "45443"})
      assert Network.https_port() == 45_443
      assert File.read!(Path.join(dir, "listen.json")) =~ "45443"

      :ok = Network.reset_ports!()
      assert Network.https_port() == 4443
    end
  end

  describe "the entrance (SSLHeaders)" do
    setup do
      Application.put_env(:ask_drive, :ssl_enabled, true)
      {:ok, _, :applied} = Network.update(%{"trusted_proxies" => "10.0.0.2"})
      :ok
    end

    defp enter(conn), do: AskDriveWeb.Plugs.SSLHeaders.call(conn, [])

    test "plain HTTP from anyone but a trusted proxy is redirected to HTTPS" do
      conn =
        conn(:get, "http://askdrive.local:4000/hr?x=1")
        |> Map.put(:remote_ip, {192, 168, 1, 50})
        |> enter()

      assert conn.halted
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["https://askdrive.local:4443/hr?x=1"]
    end

    test "HTTP from a trusted proxy is served, with the public scheme/host and the client's address" do
      conn =
        conn(:get, "http://askdrive.local:4000/hr")
        |> Map.put(:remote_ip, {10, 0, 0, 2})
        |> put_req_header("x-forwarded-proto", "https")
        |> put_req_header("x-forwarded-host", "ask.example.com")
        |> put_req_header("x-forwarded-port", "443")
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> enter()

      refute conn.halted
      assert conn.scheme == :https
      assert conn.host == "ask.example.com"
      assert conn.remote_ip == {203, 0, 113, 9}
    end

    test "forwarded headers from anyone else are ignored" do
      conn =
        conn(:get, "https://askdrive.local:4443/hr")
        |> Map.put(:remote_ip, {192, 168, 1, 50})
        |> put_req_header("x-forwarded-for", "1.2.3.4")
        |> put_req_header("x-forwarded-host", "evil.example.com")
        |> enter()

      refute conn.halted
      assert conn.remote_ip == {192, 168, 1, 50}
      assert conn.host == "askdrive.local"
    end

    test "with HTTPS off (ASK_DRIVE_SSL=false) nothing is redirected" do
      Application.put_env(:ask_drive, :ssl_enabled, false)

      conn =
        conn(:get, "http://askdrive.local:4000/hr")
        |> Map.put(:remote_ip, {192, 168, 1, 50})
        |> enter()

      refute conn.halted
    end
  end

  test "mix ask_drive.network (./app.sh network) status / proxy-off / ports-reset" do
    {:ok, _, :applied} = Network.update(%{"trusted_proxies" => "10.0.0.2"})
    run = &ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.AskDrive.Network.run(&1) end)

    assert run.(["status"]) =~ "10.0.0.2"
    assert run.(["proxy-off"]) =~ "解除しました"
    assert Network.trusted_proxies() == []
    assert run.(["ports-reset"]) =~ "HTTPS 4443"
  end
end
