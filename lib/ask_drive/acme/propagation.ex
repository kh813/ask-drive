defmodule AskDrive.ACME.Propagation do
  @moduledoc """
  Waits until a DNS-01 TXT record is visible before Let's Encrypt is asked to check it: an
  early check fails the authorization and costs a retry (and Let's Encrypt limits failed
  validations). The zone's authoritative name servers are asked directly, without recursion,
  so no resolver's cache is in the way; every one of them must return the value, since Let's
  Encrypt may ask any.
  """

  @doc """
  Options: `:zone` (whose NS records name the servers to ask), `:log`, `:timeout_ms`
  (default 10 minutes), `:interval_ms` (default 10 s). Returns `:ok` or `{:error, message}`.
  """
  def wait(fqdn, value, opts) do
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    timeout = Keyword.get(opts, :timeout_ms, 600_000)
    interval = Keyword.get(opts, :interval_ms, 10_000)

    case authoritative_servers(Keyword.get(opts, :zone)) do
      [] ->
        # no NS answer (e.g. the server can't reach DNS directly): give the provider time
        log.("権威 DNS サーバーを確認できないため、#{div(timeout, 10_000)} 秒待ってから確認を依頼します")
        Process.sleep(div(timeout, 10))
        :ok

      servers ->
        deadline = System.monotonic_time(:millisecond) + timeout
        poll(fqdn, value, servers, deadline, interval)
    end
  end

  defp poll(fqdn, value, servers, deadline, interval) do
    if Enum.all?(servers, &has_value?(&1, fqdn, value)) do
      :ok
    else
      if System.monotonic_time(:millisecond) + interval > deadline do
        {:error, "TXT レコード #{fqdn} が時間内に DNS に反映されませんでした（DNS の管理画面で反映状況を確認してください）"}
      else
        Process.sleep(interval)
        poll(fqdn, value, servers, deadline, interval)
      end
    end
  end

  @doc "The IPv4 addresses of a zone's authoritative name servers, as `{ip, 53}`."
  def authoritative_servers(zone) when is_binary(zone) and zone != "" do
    zone
    |> String.to_charlist()
    |> :inet_res.lookup(:in, :ns)
    |> Enum.flat_map(&:inet_res.lookup(&1, :in, :a))
    |> Enum.uniq()
    |> Enum.map(&{&1, 53})
  end

  def authoritative_servers(_zone), do: []

  defp has_value?(server, fqdn, value) do
    fqdn
    |> String.to_charlist()
    |> :inet_res.lookup(:in, :txt, nameservers: [server], recurse: false, timeout: 5_000)
    |> Enum.any?(fn strings -> IO.chardata_to_string(strings) == value end)
  end
end
