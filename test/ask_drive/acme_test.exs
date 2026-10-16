defmodule AskDrive.ACMETest do
  @moduledoc "Obtaining a certificate with ACME and DNS-01 (spec F-1009), against a stub CA."
  use ExUnit.Case, async: false

  alias AskDrive.{ACME, CertHelper, StubACME, StubDNS}

  @host "ask.example.com"

  setup do
    {server, directory} = StubACME.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)
    StubDNS.reset()
    Application.put_env(:ask_drive, :acme_poll_interval_ms, 0)
    on_exit(fn -> Application.delete_env(:ask_drive, :acme_poll_interval_ms) end)

    opts = [
      directory: directory,
      account_dir: CertHelper.tmp_dir(),
      dns: {StubDNS, %{owner: self()}},
      wait_dns: fn _fqdn, _value -> :ok end
    ]

    %{opts: opts}
  end

  test "issues a certificate: signed requests, the TXT value, and the record removed after",
       %{opts: opts} do
    test_pid = self()

    assert {:ok, %{cert: cert, key: key, chain: chain}} =
             ACME.issue(@host, opts ++ [log: &send(test_pid, {:log, &1})])

    # the leaf for the host, its key, and the CA as the chain
    assert {:ok, info} = AskDrive.SSL.describe_cert(cert)
    assert info["names"] == [@host]
    assert key =~ "PRIVATE KEY"
    assert chain =~ "BEGIN CERTIFICATE"
    refute chain =~ String.trim(cert)

    # the TXT record went in and came out again
    assert_received {:stub_dns, :present, "_acme-challenge.ask.example.com"}
    assert_received {:stub_dns, :cleanup, "_acme-challenge.ask.example.com"}
    assert StubDNS.records() == %{}
    assert_received {:log, "証明書を受け取りました"}
  end

  test "the account key is made once and reused", %{opts: opts} do
    assert {:ok, _} = ACME.issue(@host, opts)
    key_path = Path.join(opts[:account_dir], "account_key.pem")
    key = File.read!(key_path)
    assert File.stat!(key_path).mode |> Bitwise.band(0o777) == 0o600

    assert {:ok, _} = ACME.issue(@host, opts)
    assert File.read!(key_path) == key
  end

  test "a badNonce answer is retried once with the fresh nonce", %{opts: opts} do
    StubACME.set(:bad_nonce_once, true)
    assert {:ok, _} = ACME.issue(@host, opts)
  end

  test "a TXT record Let's Encrypt can't see fails the run and is still removed", %{opts: opts} do
    StubACME.set(:reject_challenge, true)

    assert {:error, message} = ACME.issue(@host, opts)
    assert message =~ "TXT レコードを確認できませんでした"
    assert message =~ "No TXT record found"
    assert_received {:stub_dns, :cleanup, _}
    assert StubDNS.records() == %{}
  end

  test "DNS that can't be written stops before Let's Encrypt is asked", %{opts: opts} do
    opts = Keyword.put(opts, :dns, {StubDNS, %{owner: self(), fail_present: true}})

    assert {:error, message} = ACME.issue(@host, opts)
    assert message =~ "TXT レコードを追加できませんでした"
    refute_received {:stub_acme, "/chall/1"}
  end

  test "a record that never shows up in DNS is not submitted", %{opts: opts} do
    opts = Keyword.put(opts, :wait_dns, fn _, _ -> {:error, "反映されませんでした"} end)

    assert {:error, "反映されませんでした"} = ACME.issue(@host, opts)
    refute_received {:stub_acme, "/chall/1"}
    assert_received {:stub_dns, :cleanup, _}
  end

  test "split_chain/1 separates the leaf from the intermediates" do
    %{cert: leaf, chain: ca} = CertHelper.ca_signed([@host])
    assert {^leaf, ^ca} = ACME.split_chain(leaf <> ca)
  end
end
