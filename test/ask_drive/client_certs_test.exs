defmodule AskDrive.ClientCertsTest do
  use AskDrive.DataCase, async: false
  import Plug.Test

  alias AskDrive.{CertHelper, ClientCerts}
  alias AskDriveWeb.Plugs.ClientCertGate

  setup do
    Application.put_env(:ask_drive, :ssl_dir, CertHelper.tmp_dir())
    on_exit(fn -> Application.put_env(:ask_drive, :ssl_dir, nil) end)
    {:ok, group} = ClientCerts.create_group("経理部")
    %{group: group}
  end

  # the certificate (DER) inside an issued .p12
  defp der_of(issued) do
    dir = CertHelper.tmp_dir()
    p12 = Path.join(dir, "c.p12")
    File.write!(p12, issued.p12)

    {pem, 0} =
      System.cmd("openssl", [
        "pkcs12",
        "-in",
        p12,
        "-passin",
        "pass:" <> issued.password,
        "-clcerts",
        "-nokeys"
      ])

    [{:Certificate, der, _} | _] = :public_key.pem_decode(pem)
    der
  end

  test "issuing: a password-protected .p12 whose certificate is known here until revoked", %{
    group: group
  } do
    {:ok, issued} = ClientCerts.issue(group, "boss@example.com")
    assert String.length(issued.password) == 16
    der = der_of(issued)

    assert {:ok, %{group: %{name: "経理部"}}} = ClientCerts.check(der)
    assert issued.cert.not_after

    {:ok, _} = ClientCerts.revoke(issued.cert.id, "boss@example.com")
    assert ClientCerts.check(der) == :revoked

    # a certificate from elsewhere, and none at all
    other = CertHelper.ca_signed(["x"])
    [{:Certificate, other_der, _}] = :public_key.pem_decode(other.cert)
    assert ClientCerts.check(other_der) == :unknown
    assert ClientCerts.check(nil) == :none
  end

  # the friendly name (the .p12's bag attribute) and the subject's CN the keychain and
  # browsers show
  defp names_of(issued) do
    p12 = Path.join(CertHelper.tmp_dir(), "n.p12")
    File.write!(p12, issued.p12)

    {out, 0} =
      System.cmd(
        "openssl",
        ~w(pkcs12 -in #{p12} -clcerts -nokeys -passin pass:#{issued.password})
      )

    [_, friendly] = Regex.run(~r/friendlyName: (.+)/, out)
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der_of(issued), :otp)
    {:rdnSequence, rdns} = elem(tbs, 6)

    cn =
      for [{:AttributeTypeAndValue, {2, 5, 4, 3}, value}] <- rdns do
        case value do
          {:utf8String, v} -> to_string(v)
          {_, v} -> to_string(v)
        end
      end

    {friendly, hd(cn)}
  end

  # Some OpenSSL versions print a BMPString friendlyName by the low byte of each character
  defp printed_forms(name),
    do: [name, for(<<cp::utf8 <- name>>, into: <<>>, do: <<rem(cp, 256)>>)]

  defp local_date(dt), do: dt |> AskDrive.Clock.to_local() |> NaiveDateTime.to_date()

  test "issuing with a name, an expiry and a password of one's own", %{group: group} do
    expires = Date.add(AskDrive.Clock.local_today(), 30)

    {:ok, issued} =
      ClientCerts.issue(group, "boss@example.com", %{
        "label" => "受付の PC",
        "expires_on" => Date.to_iso8601(expires),
        "password" => "Uketsuke-2026"
      })

    assert issued.password == "Uketsuke-2026"
    assert local_date(issued.cert.not_after) == expires
    {friendly, cn} = names_of(issued)
    assert cn == "AskDrive（経理部 / 受付の PC）"
    assert friendly in printed_forms("AskDrive（経理部 / 受付の PC）")
    assert {:ok, _} = ClientCerts.check(der_of(issued))

    # without options: generated password, a year, "AskDrive（group）"
    {:ok, plain} = ClientCerts.issue(group, "boss@example.com")
    assert {_, "AskDrive（経理部）"} = names_of(plain)
    assert local_date(plain.cert.not_after) == Date.add(AskDrive.Clock.local_today(), 365)
  end

  test "issue options are checked", %{group: group} do
    today = AskDrive.Clock.local_today()
    assert {:error, msg} = ClientCerts.issue(group, "x", %{"password" => "short"})
    assert msg =~ "8〜64 文字"
    assert {:error, _} = ClientCerts.issue(group, "x", %{"password" => "has space 123"})
    assert {:error, _} = ClientCerts.issue(group, "x", %{"password" => "パスワードパスワード"})

    assert {:error, msg} =
             ClientCerts.issue(group, "x", %{"expires_on" => Date.to_iso8601(today)})

    assert msg =~ "明日以降"
    assert {:error, _} = ClientCerts.issue(group, "x", %{"expires_on" => "2026-13-40"})
    assert {:error, _} = ClientCerts.issue(group, "x", %{"label" => String.duplicate("あ", 41)})

    # not past the CA's own expiry
    ClientCerts.ensure_ca!()
    later = ClientCerts.latest_expiry() |> Date.add(1) |> Date.to_iso8601()
    assert {:error, msg} = ClientCerts.issue(group, "x", %{"expires_on" => later})
    assert msg =~ "認証局の期限"
  end

  test "downloading again: the same .p12 and password, kept encrypted; not once revoked", %{
    group: group
  } do
    {:ok, issued} = ClientCerts.issue(group, "boss@example.com")

    {:ok, %{token: token, password: password}} =
      ClientCerts.redownload(issued.cert.id, "boss@example.com")

    assert password == issued.password
    assert {:ok, body, _, _} = ClientCerts.take_download(token, "macos")
    assert body == issued.p12

    # stored encrypted, not as the .p12 itself
    %{rows: [[raw]]} =
      AskDrive.Apps.platform(fn ->
        AskDrive.Repo.query!("SELECT p12 FROM client_certs WHERE id = ?", [issued.cert.id])
      end)

    refute raw == issued.p12
    refute :binary.match(raw, issued.password) != :nomatch

    [listed] = Enum.find(ClientCerts.list_groups(), &(&1.id == group.id)).certs
    assert listed.kept? and is_nil(listed.p12)

    {:ok, _} = ClientCerts.revoke(issued.cert.id, "boss@example.com")
    assert ClientCerts.redownload(issued.cert.id, "x") == {:error, :revoked}

    # certificates issued before they were kept
    {:ok, old} =
      AskDrive.PlatformRepo.insert(%AskDrive.ClientCerts.Cert{group_id: group.id, serial: "0ld"})

    assert ClientCerts.redownload(old.id, "x") == {:error, :not_kept}
  end

  test "modes: off by default; starting / stopping asking for certificates needs a restart" do
    assert ClientCerts.mode() == "off"
    assert {:ok, true} = ClientCerts.set_mode("monitor")
    assert File.exists?(ClientCerts.ca_cert_path())
    assert {:ok, false} = ClientCerts.set_mode("enforce")
    assert ClientCerts.mode() == "enforce"
    assert {:ok, true} = ClientCerts.set_mode("off")
  end

  test "downloads per OS within 10 minutes: .pfx, .p12, and a .mobileconfig carrying the .p12" do
    token = ClientCerts.stash_download("P12BYTES", "askdrive-x.p12", "経理部", "abc123")

    assert {:ok, "P12BYTES", "askdrive-x.pfx", "application/x-pkcs12"} =
             ClientCerts.take_download(token, "windows")

    assert {:ok, "P12BYTES", "askdrive-x.p12", _} = ClientCerts.take_download(token, "macos")
    assert {:ok, "P12BYTES", "askdrive-x.p12", _} = ClientCerts.take_download(token, "android")

    assert {:ok, profile, "askdrive-x.mobileconfig", "application/x-apple-aspen-config"} =
             ClientCerts.take_download(token, "ios")

    assert profile =~ "<string>com.apple.security.pkcs12</string>"
    assert profile =~ Base.encode64("P12BYTES")
    assert profile =~ "AskDrive 証明書（経理部）"
    # the password isn't in the profile: iOS asks for it while installing
    refute profile =~ "<key>Password</key>"

    assert :error = ClientCerts.take_download("nope", "macos")
  end

  describe "the gate" do
    # a request from peer.address (Bandit sets remote_ip to the TCP peer; Plug.Test doesn't)
    defp request(peer) do
      peer = Map.merge(%{port: 1, ssl_cert: nil}, peer)

      conn(:get, "/login")
      |> put_peer_data(peer)
      |> Map.put(:remote_ip, peer.address)
      |> ClientCertGate.call([])
    end

    test "enforce: no certificate → the explanation page; a valid one → in; localhost → in", %{
      group: group
    } do
      {:ok, issued} = ClientCerts.issue(group, "boss@example.com")
      der = der_of(issued)
      {:ok, _} = ClientCerts.set_mode("enforce")

      conn = request(%{address: {192, 168, 1, 20}})
      assert conn.halted and conn.status == 403
      assert conn.resp_body =~ "電子証明書がインストールされていません"
      # the install steps, per OS, on the page the person who needs them sees
      assert conn.resp_body =~ "<summary>Windows（Chrome / Edge）</summary>"
      assert conn.resp_body =~ "証明書のインポート ウィザード"
      assert conn.resp_body =~ "<summary>iPhone / iPad（Safari）</summary>"
      assert conn.resp_body =~ "管理者権限なしで"
      # the install steps, per OS, on the page the person who needs them sees
      assert conn.resp_body =~ "<summary>Windows（Chrome / Edge）</summary>"
      assert conn.resp_body =~ "証明書のインポート ウィザード"
      assert conn.resp_body =~ "<summary>iPhone / iPad（Safari）</summary>"

      conn = request(%{address: {192, 168, 1, 20}, ssl_cert: der})
      refute conn.halted
      assert conn.assigns.client_cert.group.name == "経理部"

      refute request(%{address: {127, 0, 0, 1}}).halted
    end

    test "the office LAN needs no certificate; the setting survives a mode change (F-1408)" do
      {:ok, _} = ClientCerts.set_mode("enforce")
      assert {:error, ["bogus"]} = ClientCerts.set_lan_ranges("10.0.0.0/8, bogus")
      :ok = ClientCerts.set_lan_ranges("192.168.0.0/16  10.20.0.5")

      conn = request(%{address: {192, 168, 5, 9}})
      refute conn.halted
      assert conn.assigns.client_cert_lan
      refute request(%{address: {10, 20, 0, 5}}).halted
      assert request(%{address: {203, 0, 113, 7}}).status == 403

      {:ok, _} = ClientCerts.set_mode("monitor")
      assert ClientCerts.lan_ranges() == ["192.168.0.0/16", "10.20.0.5"]
    end

    test "through a trusted proxy, the LAN check uses the address the proxy reports" do
      {:ok, _} = ClientCerts.set_mode("enforce")
      :ok = ClientCerts.set_lan_ranges("192.168.0.0/16")
      {:ok, _, :applied} = AskDrive.Network.update(%{"trusted_proxies" => "192.168.1.1"})

      # the proxy is on the LAN, the client isn't: refused
      conn =
        conn(:get, "/login")
        |> put_peer_data(%{address: {192, 168, 1, 1}, port: 1, ssl_cert: nil})
        |> Map.put(:remote_ip, {192, 168, 1, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7")
        |> AskDriveWeb.Plugs.SSLHeaders.call([])
        |> ClientCertGate.call([])

      assert conn.status == 403
    end

    test "monitor: nobody refused; off: nothing checked" do
      {:ok, _} = ClientCerts.set_mode("monitor")
      refute request(%{address: {192, 168, 1, 20}}).halted
      {:ok, _} = ClientCerts.set_mode("off")
      refute request(%{address: {192, 168, 1, 20}}).halted
    end

    test "monitor records who still comes without a certificate" do
      {:ok, _} = ClientCerts.set_mode("monitor")
      {:ok, user} = AskDrive.Accounts.ensure_user("nocert@example.com")

      conn(:get, "/")
      |> put_peer_data(%{address: {192, 168, 1, 20}, port: 1, ssl_cert: nil})
      |> Plug.Conn.assign(:current_user, user)
      |> ClientCertGate.call([])

      assert Enum.map(ClientCerts.users_without_cert(), & &1.email) == ["nocert@example.com"]

      # from the office LAN: not listed (nobody there needs one)
      :ok = ClientCerts.set_lan_ranges("192.168.0.0/16")
      {:ok, lan_user} = AskDrive.Accounts.ensure_user("lan@example.com")

      conn(:get, "/")
      |> put_peer_data(%{address: {192, 168, 1, 30}, port: 1, ssl_cert: nil})
      |> Map.put(:remote_ip, {192, 168, 1, 30})
      |> Plug.Conn.assign(:current_user, lan_user)
      |> ClientCertGate.call([])

      refute "lan@example.com" in Enum.map(ClientCerts.users_without_cert(), & &1.email)
    end
  end

  test "the README carries the same install steps as the page" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    for {title, steps} <- AskDrive.ClientCerts.InstallGuide.sections() do
      assert readme =~ "**#{title}**"
      for step <- steps, do: assert(readme =~ step, "README is missing: #{step}")
    end
  end

  test "the README carries the page's install steps and links the beginners' guide" do
    root = Path.expand("../..", __DIR__)
    readme = File.read!(Path.join(root, "README.md"))
    assert readme =~ AskDrive.ClientCerts.InstallGuide.intro()
    assert readme =~ "CLIENT_CERT_GUIDE.md"
    assert File.read!(Path.join(root, "CLIENT_CERT_GUIDE.md")) =~ "管理者権限"

    for {title, steps} <- AskDrive.ClientCerts.InstallGuide.sections() do
      assert readme =~ "**#{title}**"
      for step <- steps, do: assert(readme =~ step, "README is missing: #{step}")
    end
  end

  test "./app.sh mtls issue / status / off" do
    run = &ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.AskDrive.Mtls.run(&1) end)
    file = Path.join(CertHelper.tmp_dir(), "cli.p12")
    assert run.(["issue", "営業部", file]) =~ "パスワード:"
    assert File.exists?(file)
    assert run.(["status"]) =~ "有効な証明書: 1 件"
    {:ok, _} = ClientCerts.set_mode("enforce")
    assert run.(["off"]) =~ "無効にしました"
    assert ClientCerts.mode() == "off"
  end
end
