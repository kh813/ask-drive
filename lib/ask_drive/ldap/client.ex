defmodule AskDrive.Ldap.Client do
  @moduledoc """
  The LDAP operations `AskDrive.Ldap` needs, over Erlang's `:eldap`. A behaviour so tests
  can stand in for a directory (config `:ldap_client`).
  """

  @type handle :: term()
  @type entry :: %{dn: String.t(), attrs: %{String.t() => [String.t()]}}

  @callback open(host :: String.t(), port :: pos_integer(), sslopts :: keyword(), timeout()) ::
              {:ok, handle} | {:error, term()}
  @callback bind(handle, dn :: String.t(), password :: String.t()) :: :ok | {:error, term()}
  @callback search(
              handle,
              base :: String.t(),
              filter :: {:mail, String.t()} | {:query, String.t()} | :base
            ) ::
              {:ok, [entry]} | {:error, term()}
  @callback close(handle) :: :ok

  @behaviour __MODULE__

  @impl true
  def open(host, port, sslopts, timeout) do
    :eldap.open([String.to_charlist(host)],
      port: port,
      ssl: true,
      sslopts: sslopts,
      timeout: timeout
    )
  end

  @impl true
  def bind(handle, dn, password) do
    :eldap.simple_bind(handle, String.to_charlist(dn), String.to_charlist(password))
  end

  @impl true
  def search(handle, base, filter) do
    {filter, scope} =
      case filter do
        {:mail, email} ->
          {:eldap.equalityMatch(~c"mail", String.to_charlist(email)), :eldap.wholeSubtree()}

        # suggestions while typing (F-1115): mail starting with, or a name containing, q
        {:query, q} ->
          q = String.to_charlist(q)

          {:eldap.or([
             :eldap.substrings(~c"mail", initial: q),
             :eldap.substrings(~c"displayName", any: q),
             :eldap.substrings(~c"cn", any: q)
           ]), :eldap.wholeSubtree()}

        :base ->
          {:eldap.present(~c"objectClass"), :eldap.baseObject()}
      end

    case :eldap.search(handle,
           base: String.to_charlist(base),
           filter: filter,
           scope: scope,
           attributes: [~c"mail", ~c"cn", ~c"displayName", ~c"uid"],
           # an exact lookup expects one entry; suggestions are trimmed afterwards
           size_limit: if(match?({:mail, _}, filter), do: 2, else: 0)
         ) do
      {:ok, result} -> {:ok, result |> elem(1) |> Enum.map(&entry/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def close(handle) do
    :eldap.close(handle)
    :ok
  end

  defp entry({:eldap_entry, dn, attrs}) do
    %{
      dn: to_string(dn),
      attrs: Map.new(attrs, fn {k, vs} -> {to_string(k), Enum.map(vs, &to_string/1)} end)
    }
  end
end
