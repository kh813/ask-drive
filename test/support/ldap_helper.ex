defmodule AskDrive.LdapHelper do
  @moduledoc "Turns on sign-in with LDAP (spec 6.13) against AskDrive.FakeLdap."
  alias AskDrive.{CertHelper, FakeLdap, Settings}

  @user %{dn: "uid=taro,ou=Users,dc=example,dc=com", password: "correct-horse", name: "山田 太郎"}

  def user, do: @user

  def enable_ldap!(extra \\ %{}) do
    FakeLdap.reset()
    FakeLdap.put_owner(self())
    FakeLdap.put_users(%{"taro@example.com" => @user})
    pem = CertHelper.ca_signed(["Google"])

    {:ok, setting} =
      Settings.update_setting(Settings.platform_setting!(), %{"allowed_domain" => "example.com"})

    {:ok, setting} =
      Settings.update_ldap(setting, Map.merge(%{"ldap_enabled" => "true"}, extra), %{
        cert: pem.cert,
        key: pem.key
      })

    {setting, pem}
  end
end
