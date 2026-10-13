defmodule AskDrive.StubACME do
  @moduledoc """
  Stand-in for a Let's Encrypt ACME server (RFC 8555), for testing `AskDrive.ACME` without
  the network. It checks what the real one checks where a client could get it wrong: every
  JWS signature (ES256, against the account's JWK), the nonce (each used once) and the `url`
  header; and for the DNS-01 challenge it computes the TXT value from the token and the
  account's JWK thumbprint itself and compares it with what the DNS stub was given
  (`AskDrive.StubDNS`). On finalize it signs the CSR with a throwaway CA (openssl).

  Options per test with `set/2`:

    * `:bad_nonce_once` — answer the first new-order with `badNonce`
    * `:reject_challenge` — the TXT record is "not found"

  Requests are reported to the owner as `{:stub_acme, path}`.
  """
  use Plug.Router

  alias AskDrive.ACME.JWS

  plug :match
  plug :dispatch

  get "/directory" do
    base = base(conn)

    json(conn, 200, %{
      "newNonce" => base <> "/new-nonce",
      "newAccount" => base <> "/new-account",
      "newOrder" => base <> "/new-order"
    })
  end

  head "/new-nonce" do
    conn |> nonce() |> send_resp(200, "")
  end

  post "/new-account" do
    with {:ok, conn, _payload} <- verify(conn, :jwk) do
      conn
      |> put_resp_header("location", base(conn) <> "/acct/1")
      |> json(201, %{"status" => "valid"})
    end
  end

  post "/new-order" do
    with {:ok, conn, %{"identifiers" => [%{"value" => host}]}} <- verify(conn, :kid) do
      if fetch(:bad_nonce_once) && !fetch(:bad_nonce_sent) do
        set(:bad_nonce_sent, true)
        problem(conn, 400, "badNonce", "JWS has an invalid anti-replay nonce")
      else
        set(:host, host)
        set(:order_status, "pending")
        set(:token, JWS.b64(:crypto.strong_rand_bytes(16)))

        conn
        |> put_resp_header("location", base(conn) <> "/order/1")
        |> json(201, order(conn))
      end
    end
  end

  post "/order/1" do
    with {:ok, conn, _} <- verify(conn, :kid), do: json(conn, 200, order(conn))
  end

  post "/authz/1" do
    with {:ok, conn, _} <- verify(conn, :kid) do
      status = if fetch(:order_status) == "pending", do: "pending", else: "valid"

      json(conn, 200, %{
        "status" => fetch(:authz_status) || status,
        "identifier" => %{"type" => "dns", "value" => fetch(:host)},
        "challenges" => [
          %{
            "type" => "dns-01",
            "url" => base(conn) <> "/chall/1",
            "token" => fetch(:token),
            "error" => fetch(:challenge_error)
          },
          %{"type" => "http-01", "url" => base(conn) <> "/chall/2", "token" => "x"}
        ]
      })
    end
  end

  post "/chall/1" do
    with {:ok, conn, _} <- verify(conn, :kid) do
      key_auth = fetch(:token) <> "." <> thumbprint(fetch(:jwk))
      expected = JWS.b64(:crypto.hash(:sha256, key_auth))
      published = AskDrive.StubDNS.records()["_acme-challenge." <> fetch(:host)]

      if published == expected and !fetch(:reject_challenge) do
        set(:order_status, "ready")
      else
        set(:authz_status, "invalid")
        set(:challenge_error, %{"detail" => "No TXT record found at _acme-challenge"})
      end

      json(conn, 200, %{"type" => "dns-01", "status" => "processing"})
    end
  end

  post "/finalize/1" do
    with {:ok, conn, %{"csr" => csr}} <- verify(conn, :kid) do
      set(:cert_chain, sign_csr(Base.url_decode64!(csr, padding: false), fetch(:host)))
      set(:order_status, "valid")
      json(conn, 200, order(conn))
    end
  end

  post "/cert/1" do
    with {:ok, conn, _} <- verify(conn, :kid) do
      conn
      |> put_resp_content_type("application/pem-certificate-chain", nil)
      |> send_resp(200, fetch(:cert_chain))
    end
  end

  # --- JWS checks --------------------------------------------------------------------------

  defp verify(conn, mode) do
    send(fetch(:owner), {:stub_acme, conn.request_path})
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"protected" => protected, "payload" => payload, "signature" => sig} = Jason.decode!(body)
    header = protected |> Base.url_decode64!(padding: false) |> Jason.decode!()

    jwk =
      case mode do
        :jwk -> header["jwk"]
        :kid -> if header["kid"] == base(conn) <> "/acct/1", do: fetch(:jwk)
      end

    cond do
      header["alg"] != "ES256" or is_nil(jwk) ->
        problem(conn, 400, "malformed", "bad alg or unknown account")

      not MapSet.member?(fetch(:nonces) || MapSet.new(), header["nonce"]) ->
        problem(conn, 400, "badNonce", "unknown or reused nonce")

      header["url"] != base(conn) <> conn.request_path ->
        problem(conn, 400, "unauthorized", "url header does not match")

      not signature_ok?(jwk, protected <> "." <> payload, sig) ->
        problem(conn, 400, "malformed", "signature does not verify")

      true ->
        set(:nonces, MapSet.delete(fetch(:nonces), header["nonce"]))
        if mode == :jwk, do: set(:jwk, jwk)

        payload =
          if payload == "",
            do: nil,
            else: payload |> Base.url_decode64!(padding: false) |> Jason.decode!()

        {:ok, nonce(conn), payload}
    end
  end

  defp signature_ok?(%{"x" => x, "y" => y}, input, sig) do
    <<r::unsigned-big-integer-size(256), s::unsigned-big-integer-size(256)>> =
      Base.url_decode64!(sig, padding: false)

    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

    point =
      <<4>> <> Base.url_decode64!(x, padding: false) <> Base.url_decode64!(y, padding: false)

    :public_key.verify(input, :sha256, der, {{:ECPoint, point}, {:namedCurve, :secp256r1}})
  end

  defp thumbprint(%{"crv" => crv, "kty" => kty, "x" => x, "y" => y}),
    do: JWS.b64(:crypto.hash(:sha256, ~s({"crv":"#{crv}","kty":"#{kty}","x":"#{x}","y":"#{y}"})))

  # --- Helpers -----------------------------------------------------------------------------

  defp order(conn) do
    status = fetch(:order_status)

    %{
      "status" => if(fetch(:authz_status) == "invalid", do: "invalid", else: status),
      "identifiers" => [%{"type" => "dns", "value" => fetch(:host)}],
      "authorizations" => [base(conn) <> "/authz/1"],
      "finalize" => base(conn) <> "/finalize/1"
    }
    |> then(fn o ->
      if status == "valid", do: Map.put(o, "certificate", base(conn) <> "/cert/1"), else: o
    end)
  end

  defp sign_csr(der, host) do
    dir = fetch(:ca_dir)

    File.write!(
      Path.join(dir, "req.csr"),
      :public_key.pem_encode([{:CertificationRequest, der, :not_encrypted}])
    )

    File.write!(
      Path.join(dir, "ext.cnf"),
      "subjectAltName=DNS:#{host}\nbasicConstraints=CA:FALSE\n"
    )

    {out, code} =
      System.cmd(
        "openssl",
        ~w(x509 -req -in req.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 90 -extfile ext.cnf),
        cd: dir,
        stderr_to_stdout: true
      )

    if code != 0, do: raise("openssl failed: #{out}")
    File.read!(Path.join(dir, "leaf.pem")) <> File.read!(Path.join(dir, "ca.pem"))
  end

  defp nonce(conn) do
    nonce = JWS.b64(:crypto.strong_rand_bytes(12))
    set(:nonces, MapSet.put(fetch(:nonces) || MapSet.new(), nonce))
    conn |> put_resp_header("replay-nonce", nonce) |> put_resp_header("cache-control", "no-store")
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  defp problem(conn, status, type, detail) do
    conn
    |> nonce()
    |> put_resp_content_type("application/problem+json")
    |> send_resp(
      status,
      Jason.encode!(%{"type" => "urn:ietf:params:acme:error:" <> type, "detail" => detail})
    )
  end

  defp base(_conn), do: fetch(:base)

  def set(key, value), do: :persistent_term.put({__MODULE__, key}, value)
  def fetch(key), do: :persistent_term.get({__MODULE__, key}, nil)

  @doc "Starts the stub with a fresh CA; returns `{pid, directory_url}`."
  def start!(owner) do
    for key <- ~w(bad_nonce_once bad_nonce_sent reject_challenge host order_status token jwk
                  nonces cert_chain authz_status challenge_error)a,
        do: set(key, nil)

    dir = AskDrive.CertHelper.tmp_dir()

    {out, 0} =
      System.cmd(
        "openssl",
        ~w(req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 30 -subj /CN=StubACME-CA),
        cd: dir,
        stderr_to_stdout: true
      )

    _ = out
    set(:ca_dir, dir)
    set(:owner, owner)
    {:ok, pid} = Bandit.start_link(plug: __MODULE__, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    set(:base, "http://127.0.0.1:#{port}")
    {pid, "http://127.0.0.1:#{port}/directory"}
  end
end
