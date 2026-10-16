defmodule AskDrive.ACME.JWS do
  @moduledoc """
  The ACME account key and the JSON Web Signatures every ACME request carries (RFC 8555 6.2,
  RFC 7515 / 7518 / 7638). The key is ECDSA P-256 and requests are signed ES256; Erlang's
  `:crypto` does the maths, so no JOSE library is needed.
  """

  @curve :secp256r1

  @doc "A new account key, as a PEM string (stored in the ACME directory, mode 0600)."
  def generate_key_pem do
    key = :public_key.generate_key({:namedCurve, @curve})
    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  end

  @doc "Reads an account key PEM."
  def decode_key(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  @doc "The public half as a JWK map (`kty`, `crv`, `x`, `y`)."
  def jwk({:ECPrivateKey, _v, _priv, _params, pub, _attrs}) do
    <<4, x::binary-size(32), y::binary-size(32)>> = pub
    %{"kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y)}
  end

  @doc """
  The JWK thumbprint (RFC 7638): SHA-256 of the required members in lexicographic order,
  with no whitespace. Part of every challenge's key authorization.
  """
  def thumbprint(key) do
    %{"crv" => crv, "kty" => kty, "x" => x, "y" => y} = jwk(key)
    json = ~s({"crv":"#{crv}","kty":"#{kty}","x":"#{x}","y":"#{y}"})
    b64(:crypto.hash(:sha256, json))
  end

  @doc """
  A flattened JWS for an ACME request. `auth` is `{:jwk, key}` (new account: the public key
  goes in the header) or `{:kid, account_url}`. A `nil` payload is a POST-as-GET (empty).
  """
  def sign(key, auth, url, nonce, payload) do
    header =
      %{"alg" => "ES256", "nonce" => nonce, "url" => url}
      |> Map.merge(
        case auth do
          {:jwk, _} -> %{"jwk" => jwk(key)}
          {:kid, kid} -> %{"kid" => kid}
        end
      )

    protected = header |> Jason.encode!() |> b64()
    payload = if is_nil(payload), do: "", else: payload |> Jason.encode!() |> b64()

    %{
      "protected" => protected,
      "payload" => payload,
      "signature" => b64(es256(key, protected <> "." <> payload))
    }
  end

  # ES256 signatures are the raw 32-byte r and s, not the DER `:crypto` returns
  defp es256({:ECPrivateKey, _v, priv, _params, _pub, _attrs}, input) do
    der = :crypto.sign(:ecdsa, :sha256, input, [priv, @curve])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::unsigned-big-integer-size(256), s::unsigned-big-integer-size(256)>>
  end

  @doc "base64url without padding."
  def b64(bin), do: Base.url_encode64(bin, padding: false)
end
