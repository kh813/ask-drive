defmodule AskDrive.LdapDirectoryTest do
  @moduledoc """
  The directory's users fetched every night (spec F-1313): e-mail fields are completed from
  that list instead of a new LDAPS connection per keystroke (about a second each), with the
  directory asked only for someone not on it.
  """
  use AskDrive.DataCase, async: false
  import AskDrive.LdapHelper

  alias AskDrive.{FakeLdap, Ldap, Settings}
  alias AskDrive.Ldap.Directory

  setup do
    {setting, _} = enable_ldap!()

    FakeLdap.put_users(%{
      "taro@example.com" => %{dn: "uid=taro,dc=example,dc=com", password: "p", name: "山田 太郎"},
      "tamaki@example.com" => %{dn: "uid=tamaki,dc=example,dc=com", password: "p", name: "佐藤 環"},
      "hanako@example.com" => %{dn: "uid=hanako,dc=example,dc=com", password: "p", name: "山田 花子"}
    })

    on_exit(&FakeLdap.reset/0)
    %{setting: setting}
  end

  defp flush_ldap do
    receive do
      {:ldap, _, _} -> flush_ldap()
    after
      0 -> :ok
    end
  end

  test "suggestions come from the fetched list, without asking the directory", %{
    setting: setting
  } do
    refute Directory.usable?(setting)
    assert {:ok, 3} = Directory.fetch()
    setting = Settings.platform_setting!()
    assert Directory.usable?(setting)
    assert setting.ldap_directory_error == nil
    flush_ldap()

    assert setting |> Ldap.search_users("ta") |> Enum.map(& &1.email) ==
             ["tamaki@example.com", "taro@example.com"]

    assert setting |> Ldap.search_users("山田") |> Enum.map(& &1.email) ==
             ["hanako@example.com", "taro@example.com"]

    refute_received {:ldap, :open, _}

    # LIKE's wildcards are taken literally (no match: the directory is asked, and has none)
    assert Directory.suggest("%a") == []
    assert Directory.suggest("ta_o") == []

    # a typo check asks only about addresses not on the list
    assert Ldap.unknown_emails(setting, ["taro@example.com", "tarou@example.com"]) ==
             {:ok, ["tarou@example.com"]}

    assert_received {:ldap, :search, {_, {:mail, "tarou@example.com"}}}
    refute_received {:ldap, :search, {_, {:mail, "taro@example.com"}}}

    flush_ldap()
    assert Ldap.unknown_emails(setting, ["taro@example.com"]) == {:ok, []}
    refute_received {:ldap, :open, _}
  end

  test "someone added since the night is still found in the directory" do
    {:ok, _} = Directory.fetch()

    FakeLdap.put_users(%{
      "jiro@example.com" => %{dn: "uid=jiro,dc=example,dc=com", password: "p", name: "鈴木 次郎"}
    })

    assert Settings.platform_setting!() |> Ldap.search_users("jiro") |> Enum.map(& &1.email) ==
             ["jiro@example.com"]
  end

  test "a fetch replaces the list; a failed one keeps it and says why" do
    {:ok, 3} = Directory.fetch()

    FakeLdap.put_users(%{
      "taro@example.com" => %{dn: "uid=taro,dc=example,dc=com", password: "p", name: "山田 太郎"}
    })

    {:ok, 1} = Directory.fetch()
    refute Directory.known?("hanako@example.com")

    FakeLdap.put_mode(:unreachable)
    assert {:error, _} = Directory.fetch()
    assert Directory.known?("taro@example.com")
    setting = Settings.platform_setting!()
    assert setting.ldap_directory_error
    # still the last good list
    assert Directory.usable?(setting)
  end

  test "changing the LDAP settings sets the list aside until fetched again" do
    {:ok, _} = Directory.fetch()

    {:ok, changed} =
      Settings.update_ldap(Settings.platform_setting!(), %{"ldap_base_dn" => "dc=other,dc=com"})

    refute Directory.usable?(changed)
  end

  test "due: tonight once, and whenever the list is missing or old" do
    setting = Settings.platform_setting!()
    day = ~N[2026-10-20 14:00:00]
    night = ~N[2026-10-21 01:00:00]

    # no list yet: at once, then not again within the hour
    assert Directory.due?(setting, day)

    {:ok, _} = Directory.fetch()
    setting = Settings.platform_setting!()
    refute Directory.due?(setting, day)

    # in the night window, if not tried since it opened (relative to that night, not to
    # today, so the test doesn't depend on the date it runs)
    window_start = AskDrive.Runtime.Mode.night_window_start_utc(night)

    {:ok, setting} =
      setting
      |> Ecto.Changeset.change(
        ldap_directory_checked_at:
          window_start |> DateTime.add(-86_400) |> DateTime.truncate(:second)
      )
      |> Repo.update()

    assert Directory.due?(setting, night)

    # LDAP off: never
    refute Directory.due?(%{setting | ldap_enabled: false}, night)
  end
end
