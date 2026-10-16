defmodule AskDrive.Ldap.Cache do
  @moduledoc """
  Makes Secure LDAP sign-in faster (spec F-1311). Two caches, in memory only (an ETS table
  owned by this process: nothing is written to disk, a restart empties them):

    * **DN** (`email → directory entry`): who the user is in the directory, so a later
      sign-in skips the search. Not a secret.
    * **Password** (`email → PBKDF2 digest`, 24 hours): after a successful sign-in the same
      password signs in again without asking the directory. Only for signing in — entering
      Platform Admin or a desk's admin screen always asks the directory. A password that
      doesn't match the digest goes to the directory, and a failed one there drops the entry.
      So a password changed or an account suspended in Google Workspace takes effect within a
      day (the next sign-in with the new password replaces the entry at once).

  Entries are keyed by a fingerprint of the LDAP settings as well, so changing them (another
  directory, certificate or base DN) makes every entry stale.
  """
  use GenServer

  @table __MODULE__
  @password_ttl 24 * 3600
  @iterations 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "How long a verified password is remembered, in seconds."
  def password_ttl, do: @password_ttl

  @doc "The directory entry cached for `email`, or nil."
  def entry(fingerprint, email) do
    case lookup({:dn, fingerprint, email}) do
      {entry, _expires} -> entry
      nil -> nil
    end
  end

  def put_entry(fingerprint, email, entry),
    do: insert({:dn, fingerprint, email}, {entry, nil})

  def drop_entry(fingerprint, email), do: delete({:dn, fingerprint, email})

  @doc "The verified result for `email` when `password` matches the remembered one, else nil."
  def verified(fingerprint, email, password) do
    with {{salt, digest, result}, expires} <- lookup({:password, fingerprint, email}),
         true <- System.system_time(:second) < expires,
         true <- :crypto.hash_equals(hash(password, salt), digest) do
      result
    else
      _ -> nil
    end
  end

  def put_verified(fingerprint, email, password, result) do
    salt = :crypto.strong_rand_bytes(16)
    expires = System.system_time(:second) + @password_ttl
    insert({:password, fingerprint, email}, {{salt, hash(password, salt), result}, expires})
  end

  def drop_verified(fingerprint, email), do: delete({:password, fingerprint, email})

  @doc "Forgets everything (tests, or after the LDAP settings change)."
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp hash(password, salt), do: :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, 32)

  # The table may not exist (a CLI task without the app's supervision tree): no caching then
  defp lookup(key) do
    case :ets.whereis(@table) != :undefined && :ets.lookup(@table, key) do
      [{^key, value, expires}] -> {value, expires}
      _ -> nil
    end
  end

  defp insert(key, {value, expires}) do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {key, value, expires})
    :ok
  end

  defp delete(key) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    :ok
  end
end
