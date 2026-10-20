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
              filter :: {:mail, String.t()} | {:query, String.t()} | :base | :people
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

  @page_size 500

  # every person with an address (F-1313), a page at a time: a directory caps how many
  # entries one search returns. A server that doesn't page answers the plain search.
  @impl true
  def search(handle, base, :people) do
    opts = [
      base: String.to_charlist(base),
      filter:
        :eldap.and([
          :eldap.equalityMatch(~c"objectClass", ~c"person"),
          :eldap.present(~c"mail")
        ]),
      scope: :eldap.wholeSubtree(),
      attributes: [~c"mail", ~c"cn", ~c"displayName"]
    ]

    case search_pages(handle, opts, :none, []) do
      {:error, :paging_unsupported} -> plain_search(handle, opts)
      other -> other
    end
  end

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

  defp search_pages(handle, opts, cookie, acc) do
    control =
      if cookie == :none,
        do: :eldap.paged_result_control(@page_size),
        else: :eldap.paged_result_control(@page_size, cookie)

    case :eldap.search(handle, opts, [control]) do
      {:ok, result} ->
        acc = [result |> elem(1) |> Enum.map(&entry/1) | acc]

        case :eldap.paged_result_cookie(result) do
          {:ok, next} when next in [~c"", ""] -> {:ok, acc |> Enum.reverse() |> Enum.concat()}
          {:ok, next} -> search_pages(handle, opts, next, acc)
          # no paging control in the answer: the server returned everything at once
          {:error, _} when cookie == :none -> {:ok, acc |> Enum.reverse() |> Enum.concat()}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} when cookie == :none and reason in [:unavailableCriticalExtension] ->
        {:error, :paging_unsupported}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plain_search(handle, opts) do
    case :eldap.search(handle, opts) do
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
