defmodule AskDrive.ACME do
  @moduledoc """
  Obtains a certificate from Let's Encrypt with the ACME protocol (RFC 8555) and the DNS-01
  challenge (spec F-1009): the server can stay on the LAN, since Let's Encrypt only looks at
  a TXT record in public DNS, never at the server itself.

  One run, `issue/2`:

    1. the account: the account key in `<ssl_dir>/acme/<staging|production>/account_key.pem`
       (made on first use); `newAccount` with that key returns the existing account, so
       nothing else is stored
    2. a new order for the host name, and for each of its authorizations the DNS-01
       challenge: the TXT record `_acme-challenge.<host>` is written through the DNS
       provider (`AskDrive.ACME.ValueDomain`), and once the authoritative name servers
       return it (`AskDrive.ACME.Propagation`) Let's Encrypt is asked to check it. The TXT
       record is removed again whatever happens
    3. a new RSA 2048 key and CSR (openssl, as for the self-signed certificate), the order
       finalized, and the certificate and its chain downloaded

  The certificate is not installed here: `AskDrive.ACME.Renewal` validates and installs it
  through `AskDrive.SSL` (with its rollback).
  """
  alias AskDrive.ACME.JWS

  @production "https://acme-v02.api.letsencrypt.org/directory"
  @staging "https://acme-staging-v02.api.letsencrypt.org/directory"

  @doc "The Let's Encrypt directory: staging (test certificates, high limits) or production."
  def directory_url(staging?) do
    Application.get_env(:ask_drive, :acme_directory_url) ||
      if(staging?, do: @staging, else: @production)
  end

  @doc """
  Obtains a certificate for `hostname`. Options:

    * `:directory` — the ACME directory URL (required)
    * `:account_dir` — where the account key lives (required)
    * `:dns` — `{module, config}`: `module.present(config, fqdn, value)` and
      `module.cleanup(config, fqdn, value)` write and remove the TXT record
    * `:wait_dns` — `fn fqdn, value -> :ok | {:error, message} end`, waits until the record
      is visible (default `AskDrive.ACME.Propagation.wait/3` with `:zone`)
    * `:zone` — the DNS zone, for the default `:wait_dns`
    * `:email` — contact for expiry notices from Let's Encrypt (optional)
    * `:log` — `fn message -> any end`, each step as it happens

  Returns `{:ok, %{cert: pem, key: pem, chain: pem}}` or `{:error, message}`.
  """
  def issue(hostname, opts) do
    log = Keyword.get(opts, :log, fn _ -> :ok end)

    with {:ok, session} <- start_session(opts, log),
         {:ok, session} <- account(session, Keyword.get(opts, :email)),
         {:ok, session, order_url, order} <- new_order(session, hostname),
         {:ok, session} <- authorize(session, order["authorizations"], opts, log),
         {:ok, key_pem, csr_der} <- generate_csr(hostname),
         {:ok, session, order} <- finalize(session, order_url, order, csr_der, log),
         {:ok, _session, pem_chain} <- download(session, order["certificate"]) do
      {cert, chain} = split_chain(pem_chain)
      log.("証明書を受け取りました")
      {:ok, %{cert: cert, key: key_pem, chain: chain}}
    end
  end

  # --- Session: directory, nonce, account --------------------------------------------------

  defp start_session(opts, log) do
    url = Keyword.fetch!(opts, :directory)
    log.("Let's Encrypt に接続しています（#{URI.parse(url).host}）")

    with {:ok, %{status: 200, body: dir}} <- request(:get, url),
         {:ok, key} <- account_key(Keyword.fetch!(opts, :account_dir)),
         {:ok, nonce} <- new_nonce(dir["newNonce"]) do
      {:ok, %{dir: dir, key: key, kid: nil, nonce: nonce}}
    else
      {:ok, %{status: status}} -> {:error, "ACME のディレクトリを取得できませんでした（HTTP #{status}）"}
      {:error, _} = error -> error
    end
  end

  defp account_key(dir) do
    path = Path.join(dir, "account_key.pem")

    unless File.exists?(path) do
      File.mkdir_p!(dir)
      File.write!(path, JWS.generate_key_pem())
      File.chmod!(path, 0o600)
    end

    {:ok, path |> File.read!() |> JWS.decode_key()}
  rescue
    e -> {:error, "ACME のアカウント鍵を読み書きできませんでした: #{Exception.message(e)}"}
  end

  defp new_nonce(url) do
    case request(:head, url) do
      {:ok, resp} when resp.status in [200, 204] -> {:ok, header(resp, "replay-nonce")}
      {:ok, resp} -> {:error, "ACME の nonce を取得できませんでした（HTTP #{resp.status}）"}
      {:error, _} = error -> error
    end
  end

  # newAccount with a key already registered returns that account (200) instead of a new one
  defp account(session, email) do
    payload =
      %{"termsOfServiceAgreed" => true}
      |> then(fn p ->
        if email in [nil, ""], do: p, else: Map.put(p, "contact", ["mailto:" <> email])
      end)

    case post(session, session.dir["newAccount"], payload, {:jwk, session.key}) do
      {:ok, session, resp} when resp.status in [200, 201] ->
        {:ok, %{session | kid: header(resp, "location")}}

      {:ok, _session, resp} ->
        {:error, problem("ACME アカウントを登録できませんでした", resp)}

      {:error, _} = error ->
        error
    end
  end

  # --- Order and authorizations -----------------------------------------------------------

  defp new_order(session, hostname) do
    payload = %{"identifiers" => [%{"type" => "dns", "value" => hostname}]}

    case post(session, session.dir["newOrder"], payload) do
      {:ok, session, %{status: 201} = resp} -> {:ok, session, header(resp, "location"), resp.body}
      {:ok, _session, resp} -> {:error, problem("証明書の注文を作成できませんでした", resp)}
      {:error, _} = error -> error
    end
  end

  defp authorize(session, urls, opts, log) do
    Enum.reduce_while(urls || [], {:ok, session}, fn url, {:ok, session} ->
      case authorize_one(session, url, opts, log) do
        {:ok, session} -> {:cont, {:ok, session}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp authorize_one(session, url, opts, log) do
    with {:ok, session, %{status: 200, body: authz}} <- post(session, url, nil) do
      domain = authz["identifier"]["value"]

      cond do
        authz["status"] == "valid" ->
          log.("#{domain} は確認済みです（前回の確認が有効）")
          {:ok, session}

        challenge = Enum.find(authz["challenges"] || [], &(&1["type"] == "dns-01")) ->
          dns_challenge(session, url, domain, challenge, opts, log)

        true ->
          {:error, "#{domain} に DNS-01 の認証方式が提示されませんでした"}
      end
    else
      {:ok, _session, resp} -> {:error, problem("認証情報を取得できませんでした", resp)}
      {:error, _} = error -> error
    end
  end

  defp dns_challenge(session, authz_url, domain, challenge, opts, log) do
    {dns, config} = Keyword.fetch!(opts, :dns)
    fqdn = "_acme-challenge." <> String.trim_leading(domain, "*.")
    value = txt_value(challenge["token"], session.key)

    wait_dns =
      Keyword.get(opts, :wait_dns) ||
        fn fqdn, value ->
          AskDrive.ACME.Propagation.wait(fqdn, value, zone: Keyword.get(opts, :zone), log: log)
        end

    log.("DNS に TXT レコード #{fqdn} を追加しています")

    case dns.present(config, fqdn, value) do
      :ok ->
        try do
          log.("TXT レコードが DNS に反映されるのを待っています")

          with :ok <- wait_dns.(fqdn, value),
               _ = log.("Let's Encrypt に TXT レコードの確認を依頼しました"),
               {:ok, session, resp} when resp.status in [200, 202] <-
                 post(session, challenge["url"], %{}),
               {:ok, session} <- poll_authz(session, authz_url, domain) do
            log.("#{domain} の所有を確認できました")
            {:ok, session}
          else
            {:ok, _session, resp} -> {:error, problem("TXT レコードの確認を依頼できませんでした", resp)}
            {:error, _} = error -> error
          end
        after
          log.("TXT レコードを削除しています")

          case dns.cleanup(config, fqdn, value) do
            :ok -> :ok
            {:error, message} -> log.("TXT レコードを削除できませんでした（手動で削除してください）: #{message}")
          end
        end

      {:error, message} ->
        # the record may have been written even so (e.g. the read-back didn't match)
        dns.cleanup(config, fqdn, value)
        {:error, "DNS に TXT レコードを追加できませんでした: #{message}"}
    end
  end

  @doc "The TXT record value for a DNS-01 challenge: base64url(SHA-256(token.thumbprint))."
  def txt_value(token, key),
    do: JWS.b64(:crypto.hash(:sha256, token <> "." <> JWS.thumbprint(key)))

  defp poll_authz(session, url, domain, tries \\ 0) do
    max_tries = poll_tries()

    case post(session, url, nil) do
      {:ok, session, %{status: 200, body: %{"status" => "valid"}}} ->
        {:ok, session}

      {:ok, _session, %{status: 200, body: %{"status" => "invalid"} = authz}} ->
        detail =
          (authz["challenges"] || [])
          |> Enum.find_value(fn c -> c["error"] && c["error"]["detail"] end)

        {:error, "Let's Encrypt が #{domain} の TXT レコードを確認できませんでした: #{detail || "理由不明"}"}

      {:ok, _session, %{status: 200}} when tries >= max_tries ->
        {:error, "#{domain} の確認が時間内に終わりませんでした"}

      {:ok, session, %{status: 200}} ->
        pause()
        poll_authz(session, url, domain, tries + 1)

      {:ok, _session, resp} ->
        {:error, problem("認証の状態を取得できませんでした", resp)}

      {:error, _} = error ->
        error
    end
  end

  # --- Key, CSR, finalize, download ------------------------------------------------------

  @doc "A new RSA 2048 key and a CSR (DER) for `hostname`, made with openssl."
  def generate_csr(hostname) do
    dir = Path.join(System.tmp_dir!(), "askdrive-acme-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    cnf = Path.join(dir, "csr.cnf")

    File.write!(cnf, """
    [req]
    distinguished_name = dn
    req_extensions = ext
    prompt = no
    [dn]
    CN = #{hostname}
    [ext]
    subjectAltName = DNS:#{hostname}
    """)

    args =
      ~w(req -new -newkey rsa:2048 -nodes -sha256 -outform DER) ++
        ["-keyout", Path.join(dir, "key.pem"), "-out", Path.join(dir, "csr.der"), "-config", cnf]

    try do
      case System.cmd(System.find_executable("openssl") || "openssl", args,
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          {:ok, File.read!(Path.join(dir, "key.pem")), File.read!(Path.join(dir, "csr.der"))}

        {output, code} ->
          {:error, "openssl で CSR を作成できませんでした (#{code}): #{output}"}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp finalize(session, order_url, order, csr_der, log) do
    log.("証明書の発行を依頼しています")

    with {:ok, session, order} <- wait_order(session, order_url, order, ["ready"]),
         {:ok, session, resp} when resp.status in [200, 201] <-
           post(session, order["finalize"], %{"csr" => JWS.b64(csr_der)}),
         {:ok, session, order} <- wait_order(session, order_url, resp.body, ["valid"]) do
      {:ok, session, order}
    else
      {:ok, _session, resp} -> {:error, problem("証明書の発行を依頼できませんでした", resp)}
      {:error, _} = error -> error
    end
  end

  defp wait_order(session, url, order, wanted, tries \\ 0) do
    status = order["status"]

    cond do
      status in wanted ->
        {:ok, session, order}

      status == "invalid" ->
        {:error, "証明書の注文が無効になりました: #{inspect(order["error"])}"}

      tries >= poll_tries() ->
        {:error, "証明書の発行が時間内に終わりませんでした（状態: #{status}）"}

      true ->
        pause()

        case post(session, url, nil) do
          {:ok, session, %{status: 200, body: order}} ->
            wait_order(session, url, order, wanted, tries + 1)

          {:ok, _session, resp} ->
            {:error, problem("注文の状態を取得できませんでした", resp)}

          {:error, _} = error ->
            error
        end
    end
  end

  defp download(session, url) when is_binary(url) do
    case post(session, url, nil, nil, [{"accept", "application/pem-certificate-chain"}]) do
      {:ok, session, %{status: 200, body: pem}} when is_binary(pem) -> {:ok, session, pem}
      {:ok, _session, resp} -> {:error, problem("証明書をダウンロードできませんでした", resp)}
      {:error, _} = error -> error
    end
  end

  defp download(_session, _url), do: {:error, "発行された証明書の URL がありませんでした"}

  @doc "Splits a PEM chain into the leaf certificate and the rest (the intermediates)."
  def split_chain(pem) do
    blocks =
      Regex.scan(~r/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/s, pem)
      |> Enum.map(fn [block] -> block <> "\n" end)

    case blocks do
      [leaf | rest] -> {leaf, Enum.join(rest)}
      [] -> {pem, ""}
    end
  end

  # --- HTTP ------------------------------------------------------------------------------

  # A signed POST (payload nil = POST-as-GET). A badNonce answer is retried once with the
  # fresh nonce it carries, as RFC 8555 6.5 asks.
  defp post(session, url, payload, auth \\ nil, headers \\ [], retried? \\ false) do
    signed_by = auth || {:kid, session.kid}
    jws = JWS.sign(session.key, signed_by, url, session.nonce, payload)

    case request(:post, url,
           body: Jason.encode!(jws),
           headers: [{"content-type", "application/jose+json"} | headers]
         ) do
      {:ok, resp} ->
        session = %{session | nonce: header(resp, "replay-nonce") || session.nonce}
        bad_nonce? = match?(%{"type" => "urn:ietf:params:acme:error:badNonce"}, resp.body)

        if resp.status == 400 and bad_nonce? and not retried? do
          post(session, url, payload, auth, headers, true)
        else
          {:ok, session, resp}
        end

      {:error, _} = error ->
        error
    end
  end

  defp request(method, url, opts \\ []) do
    opts =
      [method: method, url: url, receive_timeout: 30_000, retry: false, decode_body: false] ++
        opts ++ Application.get_env(:ask_drive, :acme_req_options, [])

    case Req.request(opts) do
      {:ok, resp} -> {:ok, %{resp | body: decode(resp)}}
      {:error, e} -> {:error, "#{URI.parse(url).host} に接続できませんでした: #{Exception.message(e)}"}
    end
  end

  # JSON and problem+json are decoded; a certificate chain stays text
  defp decode(%{body: body} = resp) when is_binary(body) and body != "" do
    if String.contains?(header(resp, "content-type") || "", "json") do
      case Jason.decode(body) do
        {:ok, json} -> json
        _ -> body
      end
    else
      body
    end
  end

  defp decode(%{body: body}), do: body

  defp header(resp, name), do: resp |> Req.Response.get_header(name) |> List.first()

  defp problem(what, %{status: status, body: %{"detail" => detail} = body}) do
    "#{what}（HTTP #{status}・#{String.replace_prefix(body["type"] || "", "urn:ietf:params:acme:error:", "")}）: #{detail}"
  end

  defp problem(what, %{status: status}), do: "#{what}（HTTP #{status}）"

  defp poll_tries, do: Application.get_env(:ask_drive, :acme_poll_tries, 60)

  defp pause do
    Process.sleep(Application.get_env(:ask_drive, :acme_poll_interval_ms, 2_000))
    true
  end
end
