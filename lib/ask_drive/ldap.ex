defmodule AskDrive.Ldap do
  @moduledoc """
  Sign-in with Google Secure LDAP (spec 6.13), or another LDAPS directory.

  Google's directory admits only LDAP clients presenting the certificate issued for them in
  the Admin console, so the connection is LDAPS with that client certificate. A sign-in then:

    1. looks the user up by e-mail (`mail`) under the base DN — as the certificate alone, or
       after binding with the optional access credentials;
    2. binds as the found DN with the password typed in. Success is the directory's own
       verification of the password; AskDrive never stores it.

  An empty password is refused before any network traffic: LDAP treats a bind with a DN and
  no password as an *unauthenticated* bind, which succeeds (RFC 4513 §5.1.2).

  Note: a password bind does not go through Google's 2-step verification.
  """

  require Logger
  alias AskDrive.Settings.Setting

  @timeout 10_000

  def default_host, do: "ldap.google.com"
  def default_port, do: 636

  @doc "Whether sign-in with LDAP is switched on and has what it needs."
  def enabled?(%Setting{} = s), do: s.ldap_enabled == true and configured?(s)

  def configured?(%Setting{} = s),
    do: present?(s.ldap_client_cert) and present?(s.ldap_client_key) and present?(base_dn(s))

  @doc "The base DN: as set, or derived from the Workspace domain (company.co.jp → dc=company,dc=co,dc=jp)."
  def base_dn(%Setting{ldap_base_dn: dn} = s) do
    if present?(dn), do: String.trim(dn), else: domain_base_dn(s.allowed_domain)
  end

  def domain_base_dn(domain) when is_binary(domain) and domain != "" do
    domain |> String.trim() |> String.split(".") |> Enum.map_join(",", &("dc=" <> &1))
  end

  def domain_base_dn(_), do: nil

  @doc """
  Verifies `email` / `password` against the directory. Returns `{:ok, %{email:, name:}}`,
  `{:error, :invalid_credentials}` (unknown user or wrong password — deliberately the same),
  or `{:error, {:unavailable, message}}` when the directory can't be reached or refuses the
  client (certificate, permissions).
  """
  def authenticate(%Setting{} = setting, email, password) do
    email = email |> to_string() |> String.trim() |> String.downcase()
    password = to_string(password)

    cond do
      not enabled?(setting) -> {:error, {:unavailable, "LDAP ログインが設定されていません"}}
      email == "" or password == "" -> {:error, :invalid_credentials}
      true -> with_connection(setting, &verify(&1, &2, setting, email, password))
    end
  end

  defp verify(client, handle, setting, email, password) do
    with :ok <- service_bind(client, handle, setting),
         {:ok, entry} <- find_user(client, handle, setting, email) do
      case client.bind(handle, entry.dn, password) do
        :ok ->
          {:ok, %{email: mail_of(entry, email), name: name_of(entry)}}

        {:error, :invalidCredentials} ->
          {:error, :invalid_credentials}

        {:error, reason} ->
          # e.g. the client lacks "verify user credentials", or the account is suspended
          Logger.warning("LDAP bind as #{entry.dn} failed: #{inspect(reason)}")
          {:error, :invalid_credentials}
      end
    end
  end

  defp service_bind(client, handle, setting) do
    if present?(setting.ldap_bind_dn) and present?(setting.ldap_bind_password) do
      case client.bind(handle, setting.ldap_bind_dn, setting.ldap_bind_password) do
        :ok -> :ok
        {:error, :ldap_closed} -> closed()
        {:error, reason} -> unavailable("アクセス認証情報でのバインドに失敗しました", reason)
      end
    else
      :ok
    end
  end

  defp find_user(client, handle, setting, email) do
    case client.search(handle, base_dn(setting), {:mail, email}) do
      {:ok, [entry]} ->
        {:ok, entry}

      {:ok, []} ->
        {:error, :invalid_credentials}

      {:ok, [_ | _]} ->
        unavailable("同じメールアドレスのユーザーが複数見つかりました", email)

      {:error, :insufficientAccessRights} ->
        unavailable("ユーザー情報を読み取る権限がありません", :insufficientAccessRights)

      {:error, :ldap_closed} ->
        closed()

      {:error, reason} ->
        unavailable("ユーザーを検索できません", reason)
    end
  end

  @doc """
  Checks the settings against the directory: TLS with the client certificate, the optional
  service bind, and reading the base DN. `:ok` or `{:error, message}`.
  """
  def test_connection(%Setting{} = setting) do
    if configured?(setting) do
      with_connection(setting, fn client, handle ->
        with :ok <- service_bind(client, handle, setting) do
          case client.search(handle, base_dn(setting), :base) do
            {:ok, _} -> :ok
            {:error, :ldap_closed} -> closed()
            {:error, reason} -> unavailable("ベース DN（#{base_dn(setting)}）を読み取れません", reason)
          end
        end
      end)
      |> case do
        :ok -> :ok
        {:error, {:unavailable, message}} -> {:error, message}
      end
    else
      {:error, "クライアント証明書・秘密鍵・ベース DN（またはドメイン）を設定してください"}
    end
  end

  defp with_connection(setting, fun) do
    client = client()
    host = host(setting)

    case sslopts(setting) do
      {:ok, opts} ->
        case client.open(host, port(setting), opts, @timeout) do
          {:ok, handle} ->
            try do
              fun.(client, handle)
            after
              client.close(handle)
            end

          {:error, reason} ->
            unavailable("#{host}:#{port(setting)} に接続できません（証明書・サービスの状態を確認してください）", reason)
        end

      {:error, message} ->
        {:error, {:unavailable, message}}
    end
  end

  @doc false
  def sslopts(%Setting{} = setting) do
    with {:ok, cert} <- first_der(setting.ldap_client_cert, :Certificate),
         {:ok, key} <- key_der(setting.ldap_client_key),
         {:ok, cacerts} <- cacerts(setting.ldap_ca_cert) do
      host = String.to_charlist(host(setting))

      {:ok,
       [
         cert: cert,
         key: key,
         verify: :verify_peer,
         cacerts: cacerts,
         server_name_indication: host,
         customize_hostname_check: [
           match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
         ],
         versions: [:"tlsv1.3", :"tlsv1.2"]
       ]}
    end
  end

  defp first_der(pem, type) do
    case :public_key.pem_decode(pem || "") do
      [{^type, der, _} | _] -> {:ok, der}
      _ -> {:error, "クライアント証明書を読み取れません"}
    end
  rescue
    _ -> {:error, "クライアント証明書を読み取れません"}
  end

  defp key_der(pem) do
    case :public_key.pem_decode(pem || "") do
      [{type, der, :not_encrypted} | _]
      when type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] ->
        {:ok, {type, der}}

      _ ->
        {:error, "クライアントの秘密鍵を読み取れません"}
    end
  rescue
    _ -> {:error, "クライアントの秘密鍵を読み取れません"}
  end

  # the system's trusted CAs (ldap.google.com has a public certificate), or the one given
  defp cacerts(pem) do
    if present?(pem) do
      case for({:Certificate, der, _} <- :public_key.pem_decode(pem), do: der) do
        [] -> {:error, "CA 証明書を読み取れません"}
        ders -> {:ok, ders}
      end
    else
      {:ok, :public_key.cacerts_get()}
    end
  rescue
    _ -> {:error, "CA 証明書を読み取れません"}
  end

  # With TLS 1.3 the server checks the client certificate after the handshake has completed
  # on our side, so a refused certificate shows up as the connection closing on the first
  # request rather than as a failed connect.
  defp closed,
    do: unavailable("LDAP サーバーが接続を切断しました（クライアント証明書が拒否された可能性があります）", :ldap_closed)

  defp unavailable(message, reason) do
    Logger.warning("LDAP: #{message}: #{inspect(reason)}")
    {:error, {:unavailable, "#{message}（#{describe(reason)}）"}}
  end

  defp describe({:tls_alert, {_, detail}}), do: "TLS: #{detail}"
  defp describe(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp describe(reason), do: inspect(reason) |> String.slice(0, 200)

  defp mail_of(entry, fallback),
    do:
      entry.attrs
      |> Map.get("mail", [])
      |> List.first()
      |> Kernel.||(fallback)
      |> String.downcase()

  defp name_of(entry) do
    Enum.find_value(["displayName", "cn"], fn attr ->
      entry.attrs |> Map.get(attr, []) |> List.first()
    end)
  end

  defp host(s), do: if(present?(s.ldap_host), do: String.trim(s.ldap_host), else: default_host())
  defp port(s), do: s.ldap_port || default_port()

  defp client, do: Application.get_env(:ask_drive, :ldap_client, AskDrive.Ldap.Client)

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
