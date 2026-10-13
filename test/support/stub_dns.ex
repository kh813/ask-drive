defmodule AskDrive.StubDNS do
  @moduledoc """
  An in-memory DNS provider for `AskDrive.ACME` tests: `present/3` and `cleanup/3` keep the
  TXT records in a map, which `AskDrive.StubACME` reads to check the challenge. Each call is
  reported to `config.owner` (when given) as `{:stub_dns, :present | :cleanup, fqdn}`.
  `config.fail_present` makes `present/3` fail.
  """

  def reset, do: :persistent_term.put(__MODULE__, %{})
  def records, do: :persistent_term.get(__MODULE__, %{})

  def present(config, fqdn, value) do
    if config[:owner], do: send(config.owner, {:stub_dns, :present, fqdn})

    if config[:fail_present] do
      {:error, "HTTP 401: API キーが正しくありません"}
    else
      :persistent_term.put(__MODULE__, Map.put(records(), fqdn, value))
      :ok
    end
  end

  def cleanup(config, fqdn, _value) do
    if config[:owner], do: send(config.owner, {:stub_dns, :cleanup, fqdn})
    :persistent_term.put(__MODULE__, Map.delete(records(), fqdn))
    :ok
  end
end
