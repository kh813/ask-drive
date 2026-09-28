defmodule AskDrive.Drive.ServiceAccountTest do
  use ExUnit.Case, async: true

  alias AskDrive.Drive.ServiceAccount

  # A throwaway 2048-bit RSA keypair generated once for these tests. Google's real keys are
  # the same PKCS#8 PEM shape, so this exercises the same decode/sign path without touching
  # real credentials.
  setup_all do
    {:ok, pem} = generate_pkcs8_pem()
    %{private_key_pem: pem}
  end

  test "parse/1 extracts the fields needed to sign requests", %{private_key_pem: pem} do
    json =
      Jason.encode!(%{
        type: "service_account",
        client_email: "sync@my-project.iam.gserviceaccount.com",
        private_key: pem,
        private_key_id: "abc123",
        token_uri: "https://oauth2.googleapis.com/token",
        project_id: "my-project"
      })

    assert {:ok, account} = ServiceAccount.parse(json)
    assert account.client_email == "sync@my-project.iam.gserviceaccount.com"
    assert account.private_key == pem
    assert account.private_key_id == "abc123"
    assert account.token_uri == "https://oauth2.googleapis.com/token"
  end

  test "parse/1 reports a clear error for malformed JSON" do
    assert {:error, reason} = ServiceAccount.parse("not json")
    assert reason =~ "JSON"
  end

  test "parse/1 reports a clear error when required fields are missing" do
    assert {:error, reason} = ServiceAccount.parse(~s({"type": "service_account"}))
    assert reason =~ "client_email"
  end

  test "build_assertion/1 produces a JWT whose signature verifies against the public key", %{
    private_key_pem: pem
  } do
    account = %{
      client_email: "sync@my-project.iam.gserviceaccount.com",
      private_key: pem,
      private_key_id: "abc123",
      token_uri: "https://oauth2.googleapis.com/token"
    }

    assert {:ok, jwt} = ServiceAccount.build_assertion(account)
    assert [header_b64, claims_b64, signature_b64] = String.split(jwt, ".")

    header = header_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert header["alg"] == "RS256"
    assert header["typ"] == "JWT"
    assert header["kid"] == "abc123"

    claims = claims_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["iss"] == account.client_email
    assert claims["scope"] == "https://www.googleapis.com/auth/drive.readonly"
    assert claims["aud"] == account.token_uri
    assert is_integer(claims["exp"])
    assert claims["exp"] > claims["iat"]

    signing_input = "#{header_b64}.#{claims_b64}"
    signature = Base.url_decode64!(signature_b64, padding: false)

    [pem_entry] = :public_key.pem_decode(pem)
    private_key = :public_key.pem_entry_decode(pem_entry)
    public_key = rsa_public_key_from_private(private_key)

    assert :public_key.verify(signing_input, :sha256, signature, public_key)
  end

  test "build_assertion/1 surfaces a clear error for a malformed private key" do
    account = %{
      client_email: "sync@my-project.iam.gserviceaccount.com",
      private_key: "not a pem",
      private_key_id: nil,
      token_uri: "https://oauth2.googleapis.com/token"
    }

    assert {:error, reason} = ServiceAccount.build_assertion(account)
    assert reason =~ "private_key"
  end

  defp rsa_public_key_from_private(
         {:RSAPrivateKey, _version, modulus, public_exponent, _d, _p, _q, _e1, _e2, _c, _other}
       ) do
    {:RSAPublicKey, modulus, public_exponent}
  end

  # Shells out to openssl (present on every macOS/Linux dev and CI box this project targets)
  # rather than depending on a pure-Elixir keypair generator that isn't in the dep tree.
  defp generate_pkcs8_pem do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "ask_drive_test_sa_#{System.unique_integer([:positive])}.pem")

    {_, 0} =
      System.cmd("openssl", [
        "genpkey",
        "-algorithm",
        "RSA",
        "-pkeyopt",
        "rsa_keygen_bits:2048",
        "-out",
        path
      ])

    pem = File.read!(path)
    File.rm(path)
    {:ok, pem}
  end
end
