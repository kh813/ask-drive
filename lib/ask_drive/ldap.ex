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

  To answer faster (F-1311), the user's directory entry is cached so a later sign-in skips
  the search, the TLS session is resumed, and — for signing in only (`remember: true`) — a
  verified password is remembered for 24 hours (`AskDrive.Ldap.Cache`).
  """

  use Gettext, backend: AskDriveWeb.Gettext
  require Logger
  alias AskDrive.Ldap.{Cache, Directory}
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
  #
  # `remember: true` (signing in, not entering an admin screen) answers from the 24-hour
  # password cache when the same password was verified before, and fills it on success.
  def authenticate(%Setting{} = setting, email, password, opts \\ []) do
    email = email |> to_string() |> String.trim() |> String.downcase()
    password = to_string(password)
    remember? = Keyword.get(opts, :remember, false)
    fp = fingerprint(setting)
    usable? = enabled?(setting) and email != "" and password != ""
    remembered = if usable? and remember?, do: Cache.verified(fp, email, password)

    cond do
      not enabled?(setting) ->
        {:error, {:unavailable, gettext("LDAP sign-in is not set up")}}

      not usable? ->
        {:error, :invalid_credentials}

      remembered ->
        {:ok, remembered}

      true ->
        case with_connection(setting, &verify(&1, &2, setting, fp, email, password)) do
          {:ok, result} ->
            if remember?, do: Cache.put_verified(fp, email, password, result)
            {:ok, result}

          {:error, :invalid_credentials} = error ->
            Cache.drop_verified(fp, email)
            error

          other ->
            other
        end
    end
  end

  # With the entry cached from an earlier sign-in, bind straight away; if that fails, the
  # entry may be stale (a renamed user), so look the user up again — binding a second time
  # only when the directory now names a different DN.
  defp verify(client, handle, setting, fp, email, password) do
    with :ok <- service_bind(client, handle, setting) do
      case Cache.entry(fp, email) do
        nil ->
          verify_found(client, handle, setting, fp, email, password)

        cached ->
          case bind_as(client, handle, cached, email, password) do
            {:ok, _} = ok ->
              ok

            {:error, :invalid_credentials} = error ->
              Cache.drop_entry(fp, email)

              case find_user(client, handle, setting, email) do
                {:ok, %{dn: dn} = entry} when dn != cached.dn ->
                  Cache.put_entry(fp, email, entry)
                  bind_as(client, handle, entry, email, password)

                {:ok, entry} ->
                  Cache.put_entry(fp, email, entry)
                  error

                other ->
                  other
              end
          end
      end
    end
  end

  defp verify_found(client, handle, setting, fp, email, password) do
    with {:ok, entry} <- find_user(client, handle, setting, email) do
      Cache.put_entry(fp, email, entry)
      bind_as(client, handle, entry, email, password)
    end
  end

  defp bind_as(client, handle, entry, email, password) do
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

  @doc """
  Every person in the directory with an address, for the night's list (F-1313):
  `{:ok, [%{email:, name:}]}` or `{:error, message}`.
  """
  def list_people(%Setting{} = setting) do
    if configured?(setting) do
      with_connection(setting, fn client, handle ->
        with :ok <- service_bind(client, handle, setting) do
          case client.search(handle, base_dn(setting), :people) do
            {:ok, entries} ->
              {:ok,
               entries
               |> Enum.flat_map(fn e ->
                 case Map.get(e.attrs, "mail", []) do
                   [mail | _] -> [%{email: String.downcase(mail), name: name_of(e)}]
                   _ -> []
                 end
               end)
               |> Enum.uniq_by(& &1.email)}

            {:error, :ldap_closed} ->
              closed()

            {:error, reason} ->
              unavailable(gettext("Can't list the directory's users"), reason)
          end
        end
      end)
      |> case do
        {:ok, people} -> {:ok, people}
        {:error, {:unavailable, message}} -> {:error, message}
      end
    else
      {:error,
       gettext("Set the client certificate, the private key and the base DN (or the domain)")}
    end
  end

  @doc "Which directory, as whom, as text: the night's list is tied to it (F-1313)."
  def settings_fingerprint(%Setting{} = setting),
    do: setting |> fingerprint() |> Base.encode16(case: :lower)

  # which directory, as whom: a change makes every cached entry stale
  defp fingerprint(setting) do
    [
      host(setting),
      to_string(port(setting)),
      base_dn(setting) || "",
      setting.ldap_client_cert || "",
      setting.ldap_bind_dn || ""
    ]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 12)
  end

  defp service_bind(client, handle, setting) do
    if present?(setting.ldap_bind_dn) and present?(setting.ldap_bind_password) do
      case client.bind(handle, setting.ldap_bind_dn, setting.ldap_bind_password) do
        :ok ->
          :ok

        {:error, :ldap_closed} ->
          closed()

        {:error, reason} ->
          unavailable(gettext("Binding with the access credentials failed"), reason)
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
        unavailable(gettext("More than one user has this email address"), email)

      {:error, :insufficientAccessRights} ->
        unavailable(
          gettext("No permission to read user information"),
          :insufficientAccessRights
        )

      {:error, :ldap_closed} ->
        closed()

      {:error, reason} ->
        unavailable(gettext("Can't search for the user"), reason)
    end
  end

  @doc """
  Directory entries matching what is being typed (spec F-1115): mail starting with `q`, or
  a name containing it. `[%{email:, name:}]`, at most `limit`, [] when LDAP is off,
  unreachable or `q` is shorter than 2 characters.

  Answered from the list fetched every night (`AskDrive.Ldap.Directory`, F-1313) when there
  is one; the directory is asked only when it has no match (someone added today) or there
  is no list yet.
  """
  def search_users(%Setting{} = setting, q, limit \\ 8) do
    q = q |> to_string() |> String.trim()

    cond do
      not enabled?(setting) or String.length(q) < 2 ->
        []

      Directory.usable?(setting) ->
        case Directory.suggest(q, limit) do
          [] -> search_directory(setting, q, limit)
          users -> users
        end

      true ->
        search_directory(setting, q, limit)
    end
  end

  defp search_directory(setting, q, limit) do
    with_connection(setting, fn client, handle ->
      with :ok <- service_bind(client, handle, setting),
           {:ok, entries} <- client.search(handle, base_dn(setting), {:query, q}) do
        {:ok,
         entries
         |> Enum.flat_map(fn e ->
           case Map.get(e.attrs, "mail", []) do
             [mail | _] -> [%{email: String.downcase(mail), name: name_of(e)}]
             _ -> []
           end
         end)
         |> Enum.uniq_by(& &1.email)
         |> Enum.sort_by(&{not String.starts_with?(&1.email, String.downcase(q)), &1.email})
         |> Enum.take(limit)}
      end
    end)
    |> case do
      {:ok, users} -> users
      _ -> []
    end
  end

  @doc """
  Which of `emails` the directory doesn't know (typos, spec F-1115). `{:ok, missing}`;
  `:skip` when LDAP is off or can't be reached (the addresses are then taken as typed).
  """
  def unknown_emails(%Setting{} = setting, emails) do
    # addresses on the night's list are known; only the others are asked about (F-1313)
    emails =
      if enabled?(setting) and Directory.usable?(setting),
        do: Enum.reject(emails, &Directory.known?/1),
        else: emails

    if emails == [] and enabled?(setting),
      do: {:ok, []},
      else: unknown_in_directory(setting, emails)
  end

  defp unknown_in_directory(setting, emails) do
    if enabled?(setting) do
      with_connection(setting, fn client, handle ->
        with :ok <- service_bind(client, handle, setting) do
          Enum.reduce_while(emails, {:ok, []}, fn email, {:ok, missing} ->
            case client.search(handle, base_dn(setting), {:mail, email}) do
              {:ok, [_ | _]} -> {:cont, {:ok, missing}}
              {:ok, []} -> {:cont, {:ok, missing ++ [email]}}
              {:error, reason} -> {:halt, {:error, {:unavailable, inspect(reason)}}}
            end
          end)
        end
      end)
      |> case do
        {:ok, missing} -> {:ok, missing}
        _ -> :skip
      end
    else
      :skip
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
            {:ok, _} ->
              :ok

            {:error, :ldap_closed} ->
              closed()

            {:error, reason} ->
              unavailable(
                gettext("Can't read the base DN (%{base_dn})",
                  base_dn: to_string(base_dn(setting))
                ),
                reason
              )
          end
        end
      end)
      |> case do
        :ok -> :ok
        {:error, {:unavailable, message}} -> {:error, message}
      end
    else
      {:error,
       gettext("Set the client certificate, the private key and the base DN (or the domain)")}
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
            unavailable(
              gettext(
                "Can't connect to %{address} (check the certificate and the service status)",
                address: "#{host}:#{port(setting)}"
              ),
              reason
            )
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
         versions: [:"tlsv1.3", :"tlsv1.2"],
         # resume the TLS session on the next connection (shorter handshake, F-1311)
         session_tickets: :auto,
         reuse_sessions: true
       ]}
    end
  end

  defp first_der(pem, type) do
    case :public_key.pem_decode(pem || "") do
      [{^type, der, _} | _] -> {:ok, der}
      _ -> {:error, gettext("Can't read the client certificate")}
    end
  rescue
    _ -> {:error, gettext("Can't read the client certificate")}
  end

  defp key_der(pem) do
    case :public_key.pem_decode(pem || "") do
      [{type, der, :not_encrypted} | _]
      when type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] ->
        {:ok, {type, der}}

      _ ->
        {:error, gettext("Can't read the client private key")}
    end
  rescue
    _ -> {:error, gettext("Can't read the client private key")}
  end

  # the system's trusted CAs (ldap.google.com has a public certificate), or the one given
  defp cacerts(pem) do
    if present?(pem) do
      case for({:Certificate, der, _} <- :public_key.pem_decode(pem), do: der) do
        [] -> {:error, gettext("Can't read the CA certificate")}
        ders -> {:ok, ders}
      end
    else
      {:ok, :public_key.cacerts_get()}
    end
  rescue
    _ -> {:error, gettext("Can't read the CA certificate")}
  end

  # With TLS 1.3 the server checks the client certificate after the handshake has completed
  # on our side, so a refused certificate shows up as the connection closing on the first
  # request rather than as a failed connect.
  defp closed,
    do:
      unavailable(
        gettext(
          "The LDAP server closed the connection (the client certificate may have been refused)"
        ),
        :ldap_closed
      )

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
