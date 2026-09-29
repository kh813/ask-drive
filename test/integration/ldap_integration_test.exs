defmodule AskDrive.LdapIntegrationTest do
  @moduledoc """
  Sign-in with LDAP (spec 6.13) against a real LDAPS server through `:eldap` — OpenLDAP set
  up by the Linux CI to demand a client certificate, as Google Secure LDAP does. Excluded by
  default; the CI runs it with `mix test --only ldap_integration` and LDAP_IT_* set.
  """
  use AskDrive.DataCase, async: false
  @moduletag :ldap_integration

  alias AskDrive.{Ldap, Settings}

  setup do
    previous = Application.get_env(:ask_drive, :ldap_client)
    Application.put_env(:ask_drive, :ldap_client, AskDrive.Ldap.Client)
    on_exit(fn -> Application.put_env(:ask_drive, :ldap_client, previous) end)

    env = &System.fetch_env!/1

    {:ok, setting} =
      Settings.update_setting(Settings.platform_setting!(), %{"allowed_domain" => "example.com"})

    {:ok, setting} =
      Settings.update_ldap(
        setting,
        %{
          "ldap_enabled" => "true",
          "ldap_host" => env.("LDAP_IT_HOST"),
          "ldap_port" => env.("LDAP_IT_PORT")
        },
        %{
          cert: File.read!(env.("LDAP_IT_CLIENT_CERT")),
          key: File.read!(env.("LDAP_IT_CLIENT_KEY")),
          ca: File.read!(env.("LDAP_IT_CA"))
        }
      )

    %{setting: setting}
  end

  test "LDAPS with the client certificate: the right password signs in, a wrong one doesn't",
       %{setting: setting} do
    assert Ldap.test_connection(setting) == :ok

    assert {:ok, %{email: "taro@example.com", name: "Taro Yamada"}} =
             Ldap.authenticate(setting, "taro@example.com", "correct-horse")

    assert {:error, :invalid_credentials} =
             Ldap.authenticate(setting, "taro@example.com", "wrong")

    assert {:error, :invalid_credentials} = Ldap.authenticate(setting, "ghost@example.com", "x")
    # an empty password never reaches the server (it would be an unauthenticated bind)
    assert {:error, :invalid_credentials} = Ldap.authenticate(setting, "taro@example.com", "")
  end

  test "the server refuses a client without its certificate", %{setting: setting} do
    other = AskDrive.CertHelper.ca_signed(["someone-else"])
    stranger = %{setting | ldap_client_cert: other.cert, ldap_client_key: other.key}

    assert {:error, {:unavailable, message}} =
             Ldap.authenticate(stranger, "taro@example.com", "correct-horse")

    assert message =~ "接続できません"
  end

  test "a server certificate from an untrusted CA is refused", %{setting: setting} do
    other = AskDrive.CertHelper.ca_signed(["x"])
    untrusted = %{setting | ldap_ca_cert: other.chain}
    assert {:error, _} = Ldap.test_connection(untrusted)
  end
end
