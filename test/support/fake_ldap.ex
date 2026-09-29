defmodule AskDrive.FakeLdap do
  @moduledoc """
  A directory for tests, in place of `:eldap` (config `:ldap_client`). `put_users/1` sets
  `%{email => %{dn:, password:, name:}}`; `put_mode/1` makes it fail like a real server
  (`:unreachable`, `:search_denied`). Every call is sent to the test process as
  `{:ldap, op, args}`.
  """
  @behaviour AskDrive.Ldap.Client

  def put_users(users), do: :persistent_term.put({__MODULE__, :users}, users)
  def put_mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)
  def put_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

  def reset do
    put_users(%{})
    put_mode(:ok)
  end

  defp users, do: :persistent_term.get({__MODULE__, :users}, %{})
  defp mode, do: :persistent_term.get({__MODULE__, :mode}, :ok)

  defp note(op, args) do
    if pid = :persistent_term.get({__MODULE__, :owner}, nil), do: send(pid, {:ldap, op, args})
  end

  @impl true
  def open(host, port, sslopts, _timeout) do
    note(:open, {host, port, sslopts})

    if mode() == :unreachable,
      do: {:error, {:tls_alert, {:certificate_required, ~c"certificate required"}}},
      else: {:ok, make_ref()}
  end

  @impl true
  def bind(_handle, dn, password) do
    note(:bind, {dn, password})

    cond do
      dn == "uid=svc,dc=example,dc=com" and password == "svc-pass" -> :ok
      Enum.any?(users(), fn {_, u} -> u.dn == dn and u.password == password end) -> :ok
      true -> {:error, :invalidCredentials}
    end
  end

  @impl true
  def search(_handle, base, filter) do
    note(:search, {base, filter})

    case {mode(), filter} do
      {:search_denied, _} ->
        {:error, :insufficientAccessRights}

      {_, :base} ->
        {:ok, [%{dn: base, attrs: %{}}]}

      {_, {:mail, email}} ->
        case Map.get(users(), email) do
          nil -> {:ok, []}
          u -> {:ok, [%{dn: u.dn, attrs: %{"mail" => [email], "displayName" => [u.name]}}]}
        end
    end
  end

  @impl true
  def close(_handle), do: :ok
end
