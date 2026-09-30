defmodule AskDrive.SSLTest do
  use ExUnit.Case, async: false

  alias AskDrive.{CertHelper, SSL}

  test "a self-signed certificate is generated for localhost, with a private key only the owner can read" do
    dir = CertHelper.tmp_dir()
    assert {:ok, info} = SSL.generate_self_signed(dir)
    assert "localhost" in info["names"]
    assert "127.0.0.1" in info["names"]
    assert File.stat!(Path.join(dir, "key.pem")).mode |> Bitwise.band(0o077) == 0

    pem = %{
      cert: File.read!(Path.join(dir, "cert.pem")),
      key: File.read!(Path.join(dir, "key.pem"))
    }

    assert {:ok, _} = SSL.validate(pem, "localhost")
  end

  test "a CA-signed certificate with its chain validates, including the TLS handshake" do
    pem = CertHelper.ca_signed(["askdrive.example.com", "*.example.org"])
    assert {:ok, info} = SSL.validate(pem, "askdrive.example.com")
    assert info["issuer"] =~ "TestCA"

    # wildcard names match one label
    assert {:ok, _} = SSL.validate(pem, "chat.example.org")
    assert {:error, [msg]} = SSL.validate(pem, "a.b.example.org")
    assert msg =~ "含まれていません"
  end

  test "a key from another certificate, a wrong chain and garbage are all rejected" do
    a = CertHelper.ca_signed(["a.example.com"])
    b = CertHelper.ca_signed(["b.example.com"])

    assert {:error, [msg]} = SSL.validate(%{a | key: b.key})
    assert msg =~ "対になっていません"

    assert {:error, [msg]} = SSL.validate(%{a | chain: b.chain})
    assert msg =~ "中間証明書のつながり"

    assert {:error, [msg]} = SSL.validate(%{cert: "garbage", key: a.key})
    assert msg =~ "PEM"
  end

  test "a passphrase-protected key is refused with a clear message" do
    a = CertHelper.ca_signed(["a.example.com"])
    File.write!(Path.join(a.dir, "plain.key"), a.key)

    {_, 0} =
      System.cmd(
        "openssl",
        ~w(pkey -in plain.key -out enc.key -aes256 -passout pass:secret),
        cd: a.dir,
        stderr_to_stdout: true
      )

    assert {:error, [msg]} = SSL.validate(%{a | key: File.read!(Path.join(a.dir, "enc.key"))})
    assert msg =~ "パスフレーズ"
  end

  test "an expired certificate is rejected" do
    # -days 0 gives a certificate valid only for "now"; wait past it
    a = CertHelper.ca_signed(["a.example.com"], days: 0)
    Process.sleep(1100)
    assert {:error, errors} = SSL.validate(a)
    assert Enum.any?(errors, &(&1 =~ "有効期限が切れています"))
  end

  describe "install / rollback (endpoint restart stubbed)" do
    setup do
      dir = CertHelper.tmp_dir()
      Application.put_env(:ask_drive, :ssl_dir, dir)
      Application.put_env(:ask_drive, :ssl_enabled, true)
      Application.put_env(:ask_drive, :restart_endpoint_on_install, false)
      endpoint = Application.get_env(:ask_drive, AskDriveWeb.Endpoint)

      on_exit(fn ->
        Application.put_env(:ask_drive, :ssl_dir, nil)
        Application.put_env(:ask_drive, :ssl_enabled, false)
        Application.delete_env(:ask_drive, :restart_endpoint_on_install)
        Application.put_env(:ask_drive, AskDriveWeb.Endpoint, endpoint)
        :persistent_term.erase({SSL, :meta})
      end)

      %{dir: dir}
    end

    test "first boot creates a self-signed certificate; installing a custom one enables HSTS", %{
      dir: dir
    } do
      SSL.configure_endpoint!()
      assert %{"source" => "self_signed"} = SSL.current()
      refute SSL.hsts?()

      https = Application.get_env(:ask_drive, AskDriveWeb.Endpoint)[:https]
      assert https[:certfile] == Path.join([dir, "active", "cert.pem"])
      # HTTP on its own port as well: redirected to HTTPS, or served for trusted proxies
      assert Application.get_env(:ask_drive, AskDriveWeb.Endpoint)[:http][:port] ==
               AskDrive.Network.http_port()

      pem = CertHelper.ca_signed(["askdrive.example.com"])
      {:ok, info} = SSL.validate(pem)
      assert :ok = SSL.install(pem, info)

      assert %{"source" => "custom"} = SSL.current()
      assert SSL.hsts?()
      assert File.read!(Path.join([dir, "active", "cert.pem"])) == pem.cert
      assert File.exists?(Path.join([dir, "active", "chain.pem"]))
      assert File.exists?(Path.join([dir, "previous", "cert.pem"]))

      https = Application.get_env(:ask_drive, AskDriveWeb.Endpoint)[:https]
      assert get_in(https, [:thousand_island_options, :transport_options, :cacertfile])

      assert :ok = SSL.reset_to_self_signed()
      assert %{"source" => "self_signed"} = SSL.current()
      refute SSL.hsts?()
    end
  end
end
