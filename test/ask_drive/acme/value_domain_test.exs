defmodule AskDrive.ACME.ValueDomainTest do
  @moduledoc "The DNS-01 TXT record through the Value-Domain DNS API (spec F-1010)."
  use ExUnit.Case, async: false

  alias AskDrive.ACME.ValueDomain
  alias AskDrive.{CertHelper, StubValueDomain}

  @zone_text "a @ 192.0.2.1\nmx @ mail.example.com 10\ntxt @ v=spf1 include:_spf.google.com ~all\ncname www example.com."

  setup do
    {server, url} = StubValueDomain.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)
    Application.put_env(:ask_drive, :valuedomain_base_url, url)
    on_exit(fn -> Application.delete_env(:ask_drive, :valuedomain_base_url) end)
    StubValueDomain.set(:records, @zone_text)

    %{config: %{api_key: "vd-key", zone: "example.com", backup_dir: CertHelper.tmp_dir()}}
  end

  test "adds one line and leaves every other record exactly as it was", %{config: config} do
    assert :ok = ValueDomain.present(config, "_acme-challenge.ask.example.com.", "abc123")

    assert StubValueDomain.fetch(:records) == @zone_text <> "\ntxt _acme-challenge.ask abc123"

    assert_received {:stub_vd, "GET", "example.com", _, "Bearer vd-key"}
    assert_received {:stub_vd, "PUT", "example.com", body, "Bearer vd-key"}
    # ns_type and ttl go back as they were
    assert body["ns_type"] == "valuedomain1"
    assert body["ttl"] == 3600

    # the zone as it was is backed up first, readable only by the server's user
    [backup] = File.ls!(config.backup_dir)
    path = Path.join(config.backup_dir, backup)
    assert File.read!(path) == @zone_text
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "cleanup takes the same line out again: the zone is back byte for byte", %{config: config} do
    :ok = ValueDomain.present(config, "_acme-challenge.ask.example.com", "abc123")
    :ok = ValueDomain.cleanup(config, "_acme-challenge.ask.example.com", "abc123")
    assert StubValueDomain.fetch(:records) == @zone_text

    # nothing to remove: no PUT
    flush()
    :ok = ValueDomain.cleanup(config, "_acme-challenge.ask.example.com", "abc123")
    refute_received {:stub_vd, "PUT", _, _, _}
  end

  test "CRLF zones keep their line endings", %{config: config} do
    crlf = String.replace(@zone_text, "\n", "\r\n")
    StubValueDomain.set(:records, crlf)

    :ok = ValueDomain.present(config, "_acme-challenge.ask.example.com", "v")
    assert StubValueDomain.fetch(:records) == crlf <> "\r\ntxt _acme-challenge.ask v"
    :ok = ValueDomain.cleanup(config, "_acme-challenge.ask.example.com", "v")
    assert StubValueDomain.fetch(:records) == crlf
  end

  test "a zone that comes back with another record changed is reported, with the backup",
       %{config: config} do
    StubValueDomain.set(:drop_first_line_on_put, true)

    assert {:error, message} = ValueDomain.present(config, "_acme-challenge.ask.example.com", "v")
    assert message =~ "想定どおりに更新されませんでした"
    assert message =~ config.backup_dir
  end

  test "a wrong API key is said plainly, and nothing is written", %{config: config} do
    StubValueDomain.set(:status, 401)

    assert {:error, message} = ValueDomain.present(config, "_acme-challenge.ask.example.com", "v")
    assert message =~ "API キーが正しくありません"
    refute_received {:stub_vd, "PUT", _, _, _}
  end

  test "a host outside the zone is refused before any request", %{config: config} do
    assert {:error, message} = ValueDomain.present(config, "_acme-challenge.ask.other.org", "v")
    assert message =~ "含まれません"
    refute_received {:stub_vd, _, _, _, _}
  end

  test "test/1 reads the zone without changing it", %{config: config} do
    assert {:ok, 4} = ValueDomain.test(config)
    refute_received {:stub_vd, "PUT", _, _, _}
  end

  test "relative_host/2" do
    assert {:ok, "_acme-challenge.ask"} =
             ValueDomain.relative_host("_acme-challenge.Ask.Example.com.", "example.com")

    assert {:ok, "_acme-challenge"} =
             ValueDomain.relative_host("_acme-challenge.example.co.jp", "example.co.jp")
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
