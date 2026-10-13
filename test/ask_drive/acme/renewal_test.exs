defmodule AskDrive.ACME.RenewalTest do
  @moduledoc "Getting, installing and renewing the Let's Encrypt certificate (F-1009, F-1011)."
  use AskDrive.DataCase, async: false

  alias AskDrive.ACME.Renewal
  alias AskDrive.{CertHelper, Settings, SSL, StubACME, StubDNS}

  @host "ask.example.com"

  setup do
    {server, directory} = StubACME.start!(self())
    StubDNS.reset()
    endpoint = Application.get_env(:ask_drive, AskDriveWeb.Endpoint)

    env = [
      ssl_dir: CertHelper.tmp_dir(),
      ssl_enabled: true,
      restart_endpoint_on_install: false,
      acme_directory_url: directory,
      acme_dns_module: StubDNS,
      acme_issue_options: [wait_dns: fn _, _ -> :ok end],
      acme_poll_interval_ms: 0
    ]

    for {k, v} <- env, do: Application.put_env(:ask_drive, k, v)
    SSL.configure_endpoint!()

    on_exit(fn ->
      Process.exit(server, :normal)
      for {k, _} <- env, do: Application.delete_env(:ask_drive, k)
      Application.put_env(:ask_drive, AskDriveWeb.Endpoint, endpoint)
      :persistent_term.erase({SSL, :meta})
    end)

    :ok
  end

  defp enable!(attrs \\ %{}) do
    {:ok, setting} =
      Settings.update_acme(
        Settings.get_setting!(),
        Map.merge(
          %{
            "acme_enabled" => "true",
            "acme_hostname" => @host,
            "acme_dns_zone" => "example.com",
            "valuedomain_api_key" => "vd-key"
          },
          attrs
        )
      )

    setting
  end

  defp run_and_wait do
    Phoenix.PubSub.subscribe(AskDrive.PubSub, Renewal.topic())
    assert :ok = Renewal.run("テスト")
    assert_receive {:acme_status, %{running?: false} = status}, 10_000
    status
  end

  test "a run gets the certificate, installs it and records the result" do
    enable!()
    assert SSL.current()["source"] == "self_signed"

    status = run_and_wait()

    cert = SSL.current()
    assert cert["source"] == "letsencrypt"
    assert cert["names"] == [@host]
    assert cert["acme_staging"] == false
    # the previous (self-signed) certificate is kept for rollback
    assert File.exists?(Path.join(SSL.previous_dir(), "cert.pem"))

    setting = Settings.get_setting!()
    assert setting.acme_last_ok
    assert setting.acme_last_result =~ "#{@host} の証明書を取得して適用しました"
    assert setting.acme_checked_at
    assert Enum.any?(status.log, &(&1 =~ "完了"))

    # a fresh Let's Encrypt certificate for the host needs nothing more
    refute Renewal.needs_certificate?(setting)
    assert SSL.hsts?()
  end

  test "a failed run keeps the certificate being served and says why" do
    enable!()
    StubACME.set(:reject_challenge, true)

    run_and_wait()

    assert SSL.current()["source"] == "self_signed"
    setting = Settings.get_setting!()
    refute setting.acme_last_ok
    assert setting.acme_last_result =~ "TXT レコードを確認できませんでした"
  end

  test "a run needs the settings, and only one runs at a time" do
    assert {:error, :not_configured} = Renewal.run("テスト")

    enable!()
    Phoenix.PubSub.subscribe(AskDrive.PubSub, Renewal.topic())
    assert :ok = Renewal.run("テスト")
    assert {:error, :running} = Renewal.run("テスト")
    assert_receive {:acme_status, %{running?: false}}, 10_000
  end

  describe "needs_certificate?/3" do
    setup do
      %{setting: %{acme_hostname: @host, acme_staging: false}}
    end

    defp le_cert(from, to, attrs \\ %{}) do
      Map.merge(
        %{
          "source" => "letsencrypt",
          "names" => [@host],
          "acme_staging" => false,
          "not_before" => DateTime.to_iso8601(from),
          "not_after" => DateTime.to_iso8601(to)
        },
        attrs
      )
    end

    test "renews when a third of the lifetime is left (30 days of 90)", %{setting: setting} do
      issued = ~U[2026-10-01 00:00:00Z]
      cert = le_cert(issued, DateTime.add(issued, 90, :day))

      refute Renewal.needs_certificate?(setting, cert, DateTime.add(issued, 59, :day))
      assert Renewal.needs_certificate?(setting, cert, DateTime.add(issued, 61, :day))
      assert Renewal.renew_after(cert) == DateTime.add(issued, 60, :day)
    end

    test "follows shorter lifetimes by itself", %{setting: setting} do
      issued = ~U[2026-10-01 00:00:00Z]
      cert = le_cert(issued, DateTime.add(issued, 45, :day))

      refute Renewal.needs_certificate?(setting, cert, DateTime.add(issued, 29, :day))
      assert Renewal.needs_certificate?(setting, cert, DateTime.add(issued, 31, :day))
    end

    test "replaces anything that isn't a Let's Encrypt certificate for the host",
         %{setting: setting} do
      issued = DateTime.utc_now()
      fresh = le_cert(issued, DateTime.add(issued, 90, :day))

      refute Renewal.needs_certificate?(setting, fresh)
      assert Renewal.needs_certificate?(setting, nil)
      assert Renewal.needs_certificate?(setting, %{fresh | "source" => "self_signed"})
      assert Renewal.needs_certificate?(setting, %{fresh | "names" => ["old.example.com"]})
      # switching between staging and production gets a new one
      assert Renewal.needs_certificate?(setting, %{fresh | "acme_staging" => true})
    end
  end

  describe "settings" do
    test "turning it on needs the host, its zone and the API key" do
      assert {:error, cs} =
               Settings.update_acme(Settings.get_setting!(), %{"acme_enabled" => "true"})

      assert cs.errors[:acme_hostname]
      assert cs.errors[:acme_dns_zone]
      assert cs.errors[:valuedomain_api_key]
    end

    test "the host must be inside the zone; names are tidied" do
      assert {:error, cs} =
               Settings.update_acme(Settings.get_setting!(), %{
                 "acme_hostname" => "ask.example.com",
                 "acme_dns_zone" => "example.org"
               })

      assert cs.errors[:acme_hostname]

      setting = enable!(%{"acme_hostname" => " Ask.Example.com. "})
      assert setting.acme_hostname == "ask.example.com"
    end

    test "a blank API key keeps the stored one" do
      enable!()

      {:ok, setting} =
        Settings.update_acme(Settings.get_setting!(), %{
          "acme_email" => "it@example.com",
          "valuedomain_api_key" => ""
        })

      assert setting.valuedomain_api_key == "vd-key"
      assert setting.acme_email == "it@example.com"
    end
  end
end
