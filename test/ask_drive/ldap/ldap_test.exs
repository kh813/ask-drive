defmodule AskDrive.LdapTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.{CertHelper, FakeLdap, Ldap, Settings}
  import AskDrive.LdapHelper

  setup do
    on_exit(&FakeLdap.reset/0)
  end

  test "a known user with the right password signs in; the e-mail and name come from the directory" do
    {setting, _} = enable_ldap!()

    assert {:ok, %{email: "taro@example.com", name: "山田 太郎"}} =
             Ldap.authenticate(setting, " Taro@Example.com ", "correct-horse")

    # looked up by mail under the base DN derived from the domain, then bound as that DN
    assert_received {:ldap, :open, {"ldap.google.com", 636, sslopts}}
    assert_received {:ldap, :search, {"dc=example,dc=com", {:mail, "taro@example.com"}}}
    assert_received {:ldap, :bind, {"uid=taro,ou=Users,dc=example,dc=com", "correct-horse"}}

    # LDAPS with the client certificate, and the server certificate verified by host name
    assert is_binary(sslopts[:cert])
    assert {key_type, key_der} = sslopts[:key]
    assert key_type in [:RSAPrivateKey, :PrivateKeyInfo, :ECPrivateKey] and is_binary(key_der)
    assert sslopts[:verify] == :verify_peer
    assert sslopts[:server_name_indication] == ~c"ldap.google.com"
    assert sslopts[:cacerts] != []
  end

  test "a wrong password and an unknown user get the same answer" do
    {setting, _} = enable_ldap!()
    assert {:error, :invalid_credentials} = Ldap.authenticate(setting, "taro@example.com", "nope")
    assert {:error, :invalid_credentials} = Ldap.authenticate(setting, "ghost@example.com", "x")
  end

  test "an empty password is refused before any LDAP traffic (it would be an unauthenticated bind)" do
    {setting, _} = enable_ldap!()
    assert {:error, :invalid_credentials} = Ldap.authenticate(setting, "taro@example.com", "")
    refute_received {:ldap, :open, _}
  end

  test "the directory refusing the client is reported as unavailable, not as a wrong password" do
    {setting, _} = enable_ldap!()

    FakeLdap.put_mode(:unreachable)
    assert {:error, {:unavailable, msg}} = Ldap.authenticate(setting, "taro@example.com", "x")
    assert msg =~ "ldap.google.com:636"
    assert msg =~ "certificate required"

    FakeLdap.put_mode(:closed)
    assert {:error, {:unavailable, msg}} = Ldap.authenticate(setting, "taro@example.com", "x")
    assert msg =~ "クライアント証明書が拒否された可能性"

    FakeLdap.put_mode(:search_denied)
    assert {:error, {:unavailable, msg}} = Ldap.authenticate(setting, "taro@example.com", "x")
    assert msg =~ "ユーザー情報を読み取る権限がありません"
  end

  test "access credentials, when set, bind before the search" do
    {setting, _} =
      enable_ldap!(%{
        "ldap_bind_dn" => "uid=svc,dc=example,dc=com",
        "ldap_bind_password" => "svc-pass"
      })

    assert {:ok, _} = Ldap.authenticate(setting, "taro@example.com", "correct-horse")
    assert_received {:ldap, :bind, {"uid=svc,dc=example,dc=com", "svc-pass"}}
  end

  test "test_connection reads the base DN; not configured says what is missing" do
    {setting, _} = enable_ldap!()
    assert Ldap.test_connection(setting) == :ok
    assert_received {:ldap, :search, {"dc=example,dc=com", :base}}

    assert {:error, msg} = Ldap.test_connection(%{setting | ldap_client_cert: nil})
    assert msg =~ "クライアント証明書"
  end

  test "base DN: as set, else from the domain" do
    assert Ldap.domain_base_dn("company.co.jp") == "dc=company,dc=co,dc=jp"
    {setting, _} = enable_ldap!(%{"ldap_base_dn" => "ou=Users,dc=example,dc=com"})
    assert Ldap.base_dn(setting) == "ou=Users,dc=example,dc=com"
  end

  describe "saving the settings" do
    test "a key that doesn't belong to the certificate is rejected" do
      a = CertHelper.ca_signed(["Google"])
      b = CertHelper.ca_signed(["Google"])

      assert {:error, cs} =
               Settings.update_ldap(Settings.platform_setting!(), %{}, %{cert: a.cert, key: b.key})

      assert errors_on(cs).ldap_client_cert |> hd() =~ "対になっていません"
    end

    test "enabling needs the certificate and key" do
      assert {:error, cs} =
               Settings.update_ldap(Settings.platform_setting!(), %{"ldap_enabled" => "true"})

      assert errors_on(cs)[:ldap_client_cert]
    end

    test "the certificate and key are stored encrypted; a blank bind password keeps the stored one" do
      {setting, pem} =
        enable_ldap!(%{
          "ldap_bind_dn" => "uid=svc,dc=example,dc=com",
          "ldap_bind_password" => "svc-pass"
        })

      assert setting.ldap_client_key == pem.key

      [[raw_key]] =
        Ecto.Adapters.SQL.query!(Repo, "SELECT ldap_client_key FROM settings LIMIT 1").rows

      refute raw_key =~ "PRIVATE KEY"

      {:ok, setting} = Settings.update_ldap(setting, %{"ldap_bind_password" => ""})
      assert setting.ldap_bind_password == "svc-pass"
    end
  end
end
