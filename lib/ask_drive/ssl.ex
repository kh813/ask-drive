defmodule AskDrive.SSL do
  @moduledoc """
  HTTPS for AskDrive (spec 6.10).

  The endpoint listens on HTTPS (default 4443) and HTTP (default 4000). HTTP is redirected
  to HTTPS (`AskDriveWeb.HTTPSRedirect`) unless it comes from a trusted reverse proxy that
  terminates TLS itself (`AskDrive.Network`, spec F-1013); the ports and proxies are set on
  the admin screen.

  Certificates live in files, not the database — the endpoint needs them before the Repo is
  up. `<ssl_dir>/active/` holds what is served (`cert.pem`, `key.pem`, optional
  `chain.pem`, `meta.json`); `<ssl_dir>/previous/` the one before, for rollback. On first
  boot a self-signed certificate is generated (openssl) for localhost, the host name and the
  LAN addresses. An administrator can replace it with their own PEM certificate: it is
  validated (parse, key pair, validity, chain, host name, a real TLS handshake), written,
  and the endpoint is restarted; if the endpoint won't start with it, the previous
  certificate is restored.
  """
  require Logger

  @self_signed_days 825

  # --- Configuration ------------------------------------------------------------

  @doc "Whether HTTPS is on (prod default; ASK_DRIVE_SSL=false restores plain HTTP)."
  def enabled?, do: Application.get_env(:ask_drive, :ssl_enabled, false)

  def https_port, do: AskDrive.Network.https_port()
  def http_port, do: AskDrive.Network.http_port()

  def ssl_dir, do: Application.get_env(:ask_drive, :ssl_dir) || Path.expand("ssl")
  def active_dir, do: Path.join(ssl_dir(), "active")
  def previous_dir, do: Path.join(ssl_dir(), "previous")

  defp path(dir, name), do: Path.join(dir, name)

  # --- Boot ---------------------------------------------------------------------

  @doc """
  Called by the application before the endpoint starts: makes sure a certificate exists
  (generating a self-signed one on first boot) and points the endpoint at it.
  """
  def configure_endpoint! do
    if enabled?() do
      unless File.exists?(path(active_dir(), "cert.pem")) do
        Logger.info("SSL: no certificate yet; generating a self-signed one")
        {:ok, _} = generate_self_signed(active_dir())
      end
    end

    put_endpoint_config()
    :ok
  end

  @doc """
  Writes the listener settings for the endpoint into the application env: HTTPS and HTTP
  when HTTPS is on, HTTP only when it is off (ASK_DRIVE_SSL=false).
  """
  def put_endpoint_config do
    if enabled?(), do: put_https_config(), else: put_http_only_config()
  end

  defp put_http_only_config do
    config = Application.get_env(:ask_drive, AskDriveWeb.Endpoint, [])

    if config[:server] do
      http = Keyword.merge(Keyword.get(config, :http) || [], port: http_port())
      Application.put_env(:ask_drive, AskDriveWeb.Endpoint, Keyword.put(config, :http, http))
    end
  end

  defp put_https_config do
    https =
      [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: https_port(),
        cipher_suite: :compatible,
        certfile: path(active_dir(), "cert.pem"),
        keyfile: path(active_dir(), "key.pem")
      ] ++
        if File.exists?(path(active_dir(), "chain.pem")),
          # Bandit takes only certfile/keyfile at the top level; other :ssl options (the
          # intermediate chain) go to the TLS transport underneath
          do: [
            thousand_island_options: [
              transport_options: [cacertfile: path(active_dir(), "chain.pem")]
            ]
          ],
          else: []

    config = Application.get_env(:ask_drive, AskDriveWeb.Endpoint, [])
    url = Keyword.merge(Keyword.get(config, :url, []), scheme: "https", port: https_port())

    # HTTP on its own port too: redirected to HTTPS, or served for a trusted proxy
    http = [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: http_port()]

    Application.put_env(
      :ask_drive,
      AskDriveWeb.Endpoint,
      Keyword.merge(config, http: http, https: https, url: url)
    )

    :persistent_term.put({__MODULE__, :meta}, read_meta(active_dir()))
  end

  @doc "Metadata of the certificate being served (cached; see `put_endpoint_config/0`)."
  def current, do: :persistent_term.get({__MODULE__, :meta}, nil)

  @doc "HSTS only once a certificate of the admin's own is in place (never self-signed)."
  def hsts?, do: enabled?() and match?(%{"source" => "custom"}, current())

  # --- Self-signed ------------------------------------------------------------------

  @doc "Generates a self-signed certificate into `dir` for localhost, host name and LAN IPs."
  def generate_self_signed(dir) do
    File.mkdir_p!(dir)
    {dns, ips} = local_names()
    cnf = path(dir, "openssl.cnf")

    File.write!(cnf, """
    [req]
    distinguished_name = dn
    x509_extensions = v3
    prompt = no
    [dn]
    CN = AskDrive (self-signed)
    O = AskDrive
    [v3]
    basicConstraints = CA:FALSE
    keyUsage = digitalSignature, keyEncipherment
    extendedKeyUsage = serverAuth
    subjectAltName = @alt
    [alt]
    #{Enum.with_index(dns, 1) |> Enum.map_join("\n", fn {n, i} -> "DNS.#{i} = #{n}" end)}
    #{Enum.with_index(ips, 1) |> Enum.map_join("\n", fn {ip, i} -> "IP.#{i} = #{ip}" end)}
    """)

    args = [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-sha256",
      "-days",
      Integer.to_string(@self_signed_days),
      "-keyout",
      path(dir, "key.pem"),
      "-out",
      path(dir, "cert.pem"),
      "-config",
      cnf
    ]

    case System.cmd(System.find_executable("openssl") || "openssl", args, stderr_to_stdout: true) do
      {_, 0} ->
        File.rm(cnf)
        File.rm(path(dir, "chain.pem"))
        File.chmod!(path(dir, "key.pem"), 0o600)
        cert_pem = File.read!(path(dir, "cert.pem"))
        {:ok, info} = describe_cert(cert_pem)
        write_meta(dir, Map.put(info, "source", "self_signed"))
        {:ok, info}

      {output, code} ->
        {:error, "openssl が失敗しました (#{code}): #{output}"}
    end
  end

  defp local_names do
    {:ok, host} = :inet.gethostname()
    host = to_string(host)

    dns =
      ["localhost", host, if(String.contains?(host, "."), do: nil, else: host <> ".local")]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ips =
      case :inet.getifaddrs() do
        {:ok, ifaces} ->
          for {_name, opts} <- ifaces,
              {:addr, {_, _, _, _} = addr} <- opts,
              do: addr |> :inet.ntoa() |> to_string()

        _ ->
          []
      end

    {dns, Enum.uniq(["127.0.0.1" | ips])}
  end

  # --- Validation -------------------------------------------------------------------

  @doc """
  Validates an uploaded certificate. `pem` is `%{cert:, key:, chain:}` (chain optional) and
  `hostname` the public host name to expect (optional). Returns `{:ok, info}` with the
  certificate's details, or `{:error, [message]}` listing every problem found.
  """
  def validate(%{cert: cert_pem, key: key_pem} = pem, hostname \\ nil) do
    chain_pem = Map.get(pem, :chain) || ""

    with {:ok, cert_der, cert} <- decode_cert(cert_pem),
         {:ok, key} <- decode_key(key_pem),
         {:ok, chain} <- decode_chain(chain_pem) do
      info = cert_info(cert)

      errors =
        []
        |> check(key_matches?(key, cert), "秘密鍵が証明書と対になっていません（別の証明書の鍵です）")
        |> check_validity(cert)
        |> check_chain(cert_der, chain)
        |> check_hostname(info, hostname)

      errors =
        if errors == [] do
          case handshake_test(cert_pem, key_pem, chain_pem) do
            :ok -> []
            {:error, reason} -> ["TLS 接続テストに失敗しました: #{reason}"]
          end
        else
          errors
        end

      if errors == [], do: {:ok, info}, else: {:error, Enum.reverse(errors)}
    else
      {:error, message} -> {:error, [message]}
    end
  end

  @doc """
  Validates a TLS *client* certificate and its key (e.g. the Google Secure LDAP client,
  spec 6.13): both readable, the key matches, and the certificate is within its validity.
  Returns `{:ok, info}` or `{:error, [message]}`.
  """
  def validate_client_pair(cert_pem, key_pem) do
    with {:ok, _der, cert} <- decode_cert(cert_pem),
         {:ok, key} <- decode_key(key_pem) do
      errors =
        []
        |> check(key_matches?(key, cert), "秘密鍵が証明書と対になっていません（別の証明書の鍵です）")
        |> check_validity(cert)

      if errors == [], do: {:ok, cert_info(cert)}, else: {:error, Enum.reverse(errors)}
    else
      {:error, message} -> {:error, [message]}
    end
  end

  defp check(errors, true, _message), do: errors
  defp check(errors, false, message), do: [message | errors]

  defp decode_cert(pem) do
    case :public_key.pem_decode(pem || "") do
      [{:Certificate, der, _} | _] -> {:ok, der, :public_key.pkix_decode_cert(der, :otp)}
      _ -> {:error, "証明書を PEM 形式として読み取れません（-----BEGIN CERTIFICATE----- で始まるファイルを指定してください）"}
    end
  rescue
    _ -> {:error, "証明書を読み取れません"}
  end

  defp decode_key(pem) do
    case :public_key.pem_decode(pem || "") do
      [{type, _der, :not_encrypted} = entry | _]
      when type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] ->
        {:ok, :public_key.pem_entry_decode(entry)}

      [{_type, _der, {_cipher, _}} | _] ->
        {:error, "パスフレーズ付きの秘密鍵には対応していません。パスフレーズを外した鍵を指定してください"}

      _ ->
        {:error, "秘密鍵を PEM 形式として読み取れません（-----BEGIN PRIVATE KEY----- 等で始まるファイルを指定してください）"}
    end
  rescue
    _ -> {:error, "秘密鍵を読み取れません"}
  end

  defp decode_chain(pem) do
    certs =
      for {:Certificate, der, _} <- :public_key.pem_decode(pem || ""),
          do: {der, :public_key.pkix_decode_cert(der, :otp)}

    {:ok, certs}
  rescue
    _ -> {:error, "中間証明書を読み取れません"}
  end

  # The key matches when something signed with it verifies against the certificate's key.
  defp key_matches?(key, cert) do
    public = cert_public_key(cert)
    data = :crypto.strong_rand_bytes(32)
    :public_key.verify(data, :sha256, :public_key.sign(data, :sha256, key), public)
  rescue
    _ -> false
  end

  defp cert_public_key(cert) do
    {:OTPCertificate, tbs, _, _} = cert
    {:OTPSubjectPublicKeyInfo, alg, key} = elem(tbs, 7)

    case alg do
      {:PublicKeyAlgorithm, _oid, {:namedCurve, curve}} -> {key, {:namedCurve, curve}}
      _ -> key
    end
  end

  defp check_validity(errors, cert) do
    {not_before, not_after} = validity(cert)
    now = DateTime.utc_now()

    cond do
      DateTime.compare(now, not_before) == :lt ->
        ["証明書の有効期間がまだ始まっていません（#{not_before} から）" | errors]

      DateTime.compare(now, not_after) == :gt ->
        ["証明書の有効期限が切れています（#{not_after} まで）" | errors]

      true ->
        errors
    end
  end

  # Each certificate must be issued (and signed) by the next one in the chain.
  defp check_chain(errors, _cert_der, []), do: errors

  defp check_chain(errors, cert_der, chain) do
    ders = [cert_der | Enum.map(chain, &elem(&1, 0))]

    broken =
      ders
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_index(fn [child, issuer] ->
        issuer_cert = :public_key.pkix_decode_cert(issuer, :otp)

        not (:public_key.pkix_is_issuer(child, issuer_cert) and
               :public_key.pkix_verify(child, cert_public_key(issuer_cert)))
      end)

    if broken,
      do: ["中間証明書のつながりが正しくありません（#{broken + 1} 番目の証明書の発行者が次の証明書と一致しません。順序を確認してください）" | errors],
      else: errors
  rescue
    _ -> ["中間証明書の検証中にエラーが発生しました" | errors]
  end

  defp check_hostname(errors, _info, host) when host in [nil, ""], do: errors

  defp check_hostname(errors, info, host) do
    host = host |> String.trim() |> String.downcase()

    if Enum.any?(info["names"], &name_matches?(&1, host)),
      do: errors,
      else: ["証明書のホスト名（#{Enum.join(info["names"], ", ")}）に #{host} が含まれていません" | errors]
  end

  defp name_matches?("*." <> base, host) do
    case String.split(host, ".", parts: 2) do
      [_label, rest] -> rest == String.downcase(base)
      _ -> false
    end
  end

  defp name_matches?(name, host), do: String.downcase(name) == host

  @doc """
  Proves the files work for TLS: serves them on a throwaway local port and connects to it.
  Catches what parsing can't, such as a key type or format the TLS stack rejects.
  """
  def handshake_test(cert_pem, key_pem, chain_pem \\ "") do
    dir = Path.join(System.tmp_dir!(), "askdrive_ssl_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      File.write!(path(dir, "cert.pem"), cert_pem)
      File.write!(path(dir, "key.pem"), key_pem)
      opts = [certfile: path(dir, "cert.pem"), keyfile: path(dir, "key.pem")]

      opts =
        if String.trim(chain_pem || "") != "" do
          File.write!(path(dir, "chain.pem"), chain_pem)
          opts ++ [cacertfile: path(dir, "chain.pem")]
        else
          opts
        end

      {:ok, _} = Application.ensure_all_started(:ssl)
      {:ok, listen} = :ssl.listen(0, [:binary, active: false, reuseaddr: true] ++ opts)
      {:ok, {_, port}} = :ssl.sockname(listen)
      parent = self()

      acceptor =
        spawn(fn ->
          result =
            with {:ok, socket} <- :ssl.transport_accept(listen, 10_000),
                 {:ok, socket} <- :ssl.handshake(socket, 10_000) do
              :ssl.close(socket)
              :ok
            end

          send(parent, {:handshake, result})
        end)

      client = :ssl.connect(~c"localhost", port, [verify: :verify_none, active: false], 10_000)
      with {:ok, socket} <- client, do: :ssl.close(socket)

      result =
        receive do
          {:handshake, :ok} -> :ok
          {:handshake, {:error, reason}} -> {:error, inspect(reason)}
        after
          10_000 -> {:error, "timeout"}
        end

      Process.exit(acceptor, :kill)
      :ssl.close(listen)

      case {client, result} do
        {{:ok, _}, :ok} -> :ok
        {{:error, reason}, _} -> {:error, inspect(reason)}
        {_, error} -> error
      end
    rescue
      e -> {:error, Exception.message(e)}
    after
      File.rm_rf(dir)
    end
  end

  # --- Certificate details --------------------------------------------------------------

  @doc "Subject, issuer, names and validity of a PEM certificate, for display."
  def describe_cert(cert_pem) do
    with {:ok, _der, cert} <- decode_cert(cert_pem), do: {:ok, cert_info(cert)}
  end

  defp cert_info(cert) do
    {:OTPCertificate, tbs, _, _} = cert
    {not_before, not_after} = validity(cert)

    %{
      "subject" => rdn_to_string(elem(tbs, 6)),
      "issuer" => rdn_to_string(elem(tbs, 4)),
      "names" => subject_alt_names(tbs),
      "not_before" => DateTime.to_iso8601(not_before),
      "not_after" => DateTime.to_iso8601(not_after)
    }
  end

  defp validity({:OTPCertificate, tbs, _, _}) do
    {:Validity, from, to} = elem(tbs, 5)
    {asn1_time(from), asn1_time(to)}
  end

  defp asn1_time({:utcTime, t}), do: parse_time(to_string(t), :utc)
  defp asn1_time({:generalTime, t}), do: parse_time(to_string(t), :general)

  defp parse_time(t, :utc) do
    <<yy::binary-2, rest::binary>> = t
    year = String.to_integer(yy)
    parse_time("#{if year >= 50, do: 1900 + year, else: 2000 + year}" <> rest, :general)
  end

  defp parse_time(
         <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2,
           _::binary>>,
         :general
       ) do
    {:ok, dt} =
      NaiveDateTime.new(
        String.to_integer(y),
        String.to_integer(mo),
        String.to_integer(d),
        String.to_integer(h),
        String.to_integer(mi),
        String.to_integer(s)
      )

    DateTime.from_naive!(dt, "Etc/UTC")
  end

  defp subject_alt_names(tbs) do
    extensions = elem(tbs, 10)

    names =
      if is_list(extensions) do
        Enum.flat_map(extensions, fn
          {:Extension, {2, 5, 29, 17}, _critical, values} ->
            for value <- values do
              case value do
                {:dNSName, name} ->
                  to_string(name)

                {:iPAddress, ip} when is_tuple(ip) ->
                  ip |> :inet.ntoa() |> to_string()

                {:iPAddress, ip} when is_binary(ip) ->
                  ip |> :binary.bin_to_list() |> List.to_tuple() |> :inet.ntoa() |> to_string()

                _ ->
                  nil
              end
            end

          _ ->
            []
        end)
      else
        []
      end

    Enum.reject(names, &is_nil/1)
  end

  defp rdn_to_string({:rdnSequence, rdns}) do
    rdns
    |> List.flatten()
    |> Enum.map(fn {:AttributeTypeAndValue, oid, value} ->
      "#{oid_name(oid)}=#{attr_value(value)}"
    end)
    |> Enum.join(", ")
  end

  defp oid_name({2, 5, 4, 3}), do: "CN"
  defp oid_name({2, 5, 4, 10}), do: "O"
  defp oid_name({2, 5, 4, 11}), do: "OU"
  defp oid_name({2, 5, 4, 6}), do: "C"
  defp oid_name({2, 5, 4, 8}), do: "ST"
  defp oid_name({2, 5, 4, 7}), do: "L"
  defp oid_name(oid), do: oid |> Tuple.to_list() |> Enum.join(".")

  defp attr_value({:utf8String, v}), do: to_string(v)
  defp attr_value({:printableString, v}), do: to_string(v)
  defp attr_value({_, v}) when is_list(v) or is_binary(v), do: to_string(v)
  defp attr_value(v) when is_list(v) or is_binary(v), do: to_string(v)
  defp attr_value(v), do: inspect(v)

  # --- Applying ---------------------------------------------------------------------

  @doc """
  Installs a validated certificate and restarts the endpoint. The current files move to
  `previous/`; if the endpoint doesn't come back with the new ones they are restored.
  `source` is "custom" (uploaded) or "self_signed" (regenerated).
  """
  def install(%{cert: cert, key: key} = pem, info, source \\ "custom") do
    staging = Path.join(ssl_dir(), "staging")
    File.rm_rf!(staging)
    File.mkdir_p!(staging)
    File.write!(path(staging, "cert.pem"), cert)
    File.write!(path(staging, "key.pem"), key)
    File.chmod!(path(staging, "key.pem"), 0o600)

    if String.trim(Map.get(pem, :chain) || "") != "",
      do: File.write!(path(staging, "chain.pem"), pem.chain)

    write_meta(
      staging,
      Map.merge(info, %{
        "source" => source,
        "installed_at" => DateTime.to_iso8601(DateTime.utc_now())
      })
    )

    swap_in(staging)
  end

  @doc "Replaces the served certificate with a freshly generated self-signed one."
  def reset_to_self_signed do
    staging = Path.join(ssl_dir(), "staging")
    File.rm_rf!(staging)

    with {:ok, _info} <- generate_self_signed(staging), do: swap_in(staging)
  end

  defp swap_in(staging) do
    File.rm_rf!(previous_dir())
    if File.exists?(active_dir()), do: File.rename!(active_dir(), previous_dir())
    File.rename!(staging, active_dir())

    case restart_endpoint() do
      :ok ->
        Logger.info("SSL: new certificate active (#{inspect(current())})")
        :ok

      {:error, reason} ->
        Logger.error(
          "SSL: endpoint failed with the new certificate (#{inspect(reason)}); rolling back"
        )

        File.rm_rf!(active_dir())
        File.rename!(previous_dir(), active_dir())
        restart_endpoint()
        {:error, "新しい証明書で HTTPS を起動できなかったため、元の証明書に戻しました: #{inspect(reason)}"}
    end
  end

  @doc "Restarts the endpoint (the HTTPS listener) so it picks up the current certificate."
  def restart_endpoint do
    put_endpoint_config()

    if Application.get_env(:ask_drive, :restart_endpoint_on_install, true) do
      with :ok <- Supervisor.terminate_child(AskDrive.Supervisor, AskDriveWeb.Endpoint),
           {:ok, _pid} <- Supervisor.restart_child(AskDrive.Supervisor, AskDriveWeb.Endpoint) do
        :ok
      else
        {:ok, _pid, _info} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  # --- Metadata -------------------------------------------------------------------------

  defp write_meta(dir, meta), do: File.write!(path(dir, "meta.json"), Jason.encode!(meta))

  defp read_meta(dir) do
    with {:ok, json} <- File.read(path(dir, "meta.json")),
         {:ok, meta} <- Jason.decode(json) do
      meta
    else
      _ ->
        case File.read(path(dir, "cert.pem")) do
          {:ok, pem} ->
            case describe_cert(pem) do
              {:ok, info} -> Map.put(info, "source", "unknown")
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end
end
