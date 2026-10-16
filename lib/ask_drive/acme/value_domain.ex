defmodule AskDrive.ACME.ValueDomain do
  @moduledoc """
  Writes and removes the DNS-01 TXT record through the Value-Domain (バリュードメイン) DNS API
  (spec F-1010).

  The API has no per-record calls: `GET /domains/{zone}/dns` returns the whole zone as text,
  one record per line (`<type> <host> <value>`, e.g. `a www 192.0.2.1`), and
  `PUT /domains/{zone}/dns` replaces it with the text sent (with the zone's `ns_type` and
  `ttl`, kept as they were). So the zone is never parsed and rebuilt: one line
  (`txt _acme-challenge.<host> <value>`) is appended to the text exactly as returned, and
  later that same line is taken out again, so every other record goes back byte for byte.
  Before each change the zone as it was is saved to `<ssl_dir>/acme/dns_backup/`, and after
  it the zone is read back and compared: if any other record changed, the run stops and
  says where the backup is.

  `config` is `%{api_key: token, zone: "example.com", backup_dir: path}`.
  """

  use Gettext, backend: AskDriveWeb.Gettext

  @base_url "https://api.value-domain.com/v1"
  @keep_backups 20

  @doc "Adds the TXT record. Returns `:ok` or `{:error, message}`."
  def present(config, fqdn, value) do
    with {:ok, host} <- relative_host(fqdn, config.zone),
         {:ok, zone} <- get_zone(config) do
      line = "txt #{host} #{value}"

      if line in lines(zone.records) do
        :ok
      else
        records = append_line(zone.records, line)
        change(config, zone, records, fn after_lines -> after_lines -- [line] end)
      end
    end
  end

  @doc "Removes the TXT record added by `present/3`. Returns `:ok` or `{:error, message}`."
  def cleanup(config, fqdn, value) do
    with {:ok, host} <- relative_host(fqdn, config.zone),
         {:ok, zone} <- get_zone(config) do
      line = "txt #{host} #{value}"

      if line in lines(zone.records) do
        records = remove_line(zone.records, line)
        change(config, zone, records, fn after_lines -> after_lines ++ [line] end)
      else
        :ok
      end
    end
  end

  @doc """
  Checks the API key and the zone without changing anything: `{:ok, record_count}` or
  `{:error, message}`. For the admin screen's 「接続テスト」.
  """
  def test(config) do
    with {:ok, zone} <- get_zone(config), do: {:ok, length(lines(zone.records))}
  end

  # --- The zone text ---------------------------------------------------------------------

  @doc "The host part of `fqdn` within `zone` (`_acme-challenge.ask` for ask.example.com)."
  def relative_host(fqdn, zone) do
    fqdn = fqdn |> String.trim_trailing(".") |> String.downcase()
    zone = zone |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    if String.ends_with?(fqdn, "." <> zone),
      do: {:ok, String.replace_suffix(fqdn, "." <> zone, "")},
      else: {:error, "#{fqdn} はドメイン #{zone} に含まれません（ホスト名と DNS のドメインを確認してください）"}
  end

  @doc "The record lines of a zone text (blank lines and surrounding spaces ignored)."
  def lines(records) do
    records
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "The zone text with `line` added at the end, in the zone's own line ending."
  def append_line(records, line) do
    sep = separator(records)
    trimmed = String.trim_trailing(records)
    if trimmed == "", do: line, else: trimmed <> sep <> line
  end

  @doc "The zone text without the lines equal to `line`; every other line is left as it is."
  def remove_line(records, line) do
    sep = separator(records)

    records
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(String.trim(&1) == line))
    |> Enum.join(sep)
  end

  defp separator(records), do: if(String.contains?(records, "\r\n"), do: "\r\n", else: "\n")

  # PUT the new text, then read the zone back: apart from our line, it must be as before
  defp change(config, zone, records, expected_from_after) do
    backup = backup!(config, zone.records)

    payload =
      %{"records" => records}
      |> put_if("ns_type", zone.ns_type)
      |> put_if("ttl", zone.ttl)

    with :ok <- put_zone(config, payload),
         {:ok, after_zone} <- get_zone(config) do
      # compared loosely (spacing, record type case), in case the API tidies the text
      expected = lines(zone.records) |> Enum.map(&normalize/1) |> Enum.sort()

      actual =
        after_zone.records
        |> lines()
        |> expected_from_after.()
        |> Enum.map(&normalize/1)
        |> Enum.sort()

      if actual == expected do
        :ok
      else
        {:error, "DNS のレコードが想定どおりに更新されませんでした。変更前のレコードを #{backup} に保存しています。DNS の管理画面で確認してください"}
      end
    end
  end

  defp normalize(line) do
    case String.split(line) do
      [type | rest] -> Enum.join([String.downcase(type) | rest], " ")
      [] -> ""
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp backup!(config, records) do
    dir = config.backup_dir
    File.mkdir_p!(dir)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S%fZ")
    path = Path.join(dir, "#{config.zone}-#{stamp}.txt")
    File.write!(path, records)
    File.chmod!(path, 0o600)

    dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, config.zone <> "-"))
    |> Enum.sort(:desc)
    |> Enum.drop(@keep_backups)
    |> Enum.each(&File.rm(Path.join(dir, &1)))

    path
  end

  # --- HTTP ------------------------------------------------------------------------------

  defp get_zone(config) do
    case request(config, :get) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_map(results) ->
        {:ok,
         %{
           records: results["records"] || "",
           ns_type: results["ns_type"],
           ttl: results["ttl"]
         }}

      {:ok, resp} ->
        {:error, http_error(gettext("Could not get the DNS records"), resp)}

      {:error, _} = error ->
        error
    end
  end

  defp put_zone(config, payload) do
    case request(config, :put, json: payload) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, resp} -> {:error, http_error(gettext("Could not update the DNS records"), resp)}
      {:error, _} = error -> error
    end
  end

  defp request(config, method, opts \\ []) do
    zone = config.zone |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    opts =
      [
        method: method,
        url:
          "#{Application.get_env(:ask_drive, :valuedomain_base_url, @base_url)}/domains/#{zone}/dns",
        auth: {:bearer, config.api_key},
        receive_timeout: 30_000,
        # 429 (rate limit) and network errors: Req waits (Retry-After) and tries again
        retry: :transient,
        max_retries: 3
      ] ++ opts ++ Application.get_env(:ask_drive, :valuedomain_req_options, [])

    case Req.request(opts) do
      {:ok, resp} ->
        {:ok, resp}

      {:error, e} ->
        {:error,
         gettext("Could not connect to the Value-Domain API: %{error}",
           error: Exception.message(e)
         )}
    end
  end

  defp http_error(what, %{status: 401}),
    do: gettext("%{what} (HTTP 401: the API key is incorrect)", what: what)

  defp http_error(what, %{status: status}) when status in [403, 404],
    do:
      gettext(
        "%{what} (HTTP %{status}: check that the domain is managed by this account)",
        what: what,
        status: to_string(status)
      )

  defp http_error(what, %{status: status, body: body}),
    do:
      gettext("%{what} (HTTP %{status}: %{body})",
        what: what,
        status: to_string(status),
        body: body |> inspect() |> String.slice(0, 200)
      )
end
