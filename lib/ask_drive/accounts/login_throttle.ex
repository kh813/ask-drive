defmodule AskDrive.Accounts.LoginThrottle do
  @moduledoc """
  Lockout for password sign-ins (spec F-1305). A password checked against LDAP bypasses
  Google's 2-step verification, so guessing must be stopped here. Employees normally sign in
  from a saved password or a password manager, so the limits leave little room for typos:

    * per account: 5 failures within 5 minutes lock the account for 15 minutes;
    * per connection environment: 10 failures within 24 hours lock that environment for
      24 hours. An environment is the browser (its device cookie), or — for a client that
      keeps no cookies, e.g. a script — the source address with its User-Agent and
      Accept-Language. Not the address alone: behind the office NAT everyone shares one,
      and one person's failures would lock the whole office out.

  Failures and locks are rows in the platform DB, so a restart or a new browser tab doesn't
  reset them. A successful sign-in clears the account's failures; an administrator can lift
  any lock (`unlock/1`).
  """

  import Ecto.Query
  alias AskDrive.Accounts.{LoginFailure, LoginLock}
  alias AskDrive.Repo

  @account_max 5
  @account_window 5 * 60
  @account_lock 15 * 60

  @env_max 10
  @env_window 24 * 3600
  @env_lock 24 * 3600

  @doc "`:ok`, or `{:locked, until, :account | :env}` when the account or environment is locked."
  def check(email, env_key, now \\ DateTime.utc_now()) do
    keys = [{"account", normalize(email)}, {"env", env_key}]

    platform(fn ->
      Repo.all(
        from l in LoginLock,
          where: l.locked_until > ^now,
          select: {l.scope, l.key, l.locked_until}
      )
    end)
    |> Enum.filter(fn {scope, key, _} -> {scope, key} in keys end)
    |> Enum.max_by(fn {_, _, until} -> DateTime.to_unix(until) end, fn -> nil end)
    |> case do
      nil ->
        :ok

      {scope, _, until} ->
        scope_atom =
          case scope do
            "account" -> :account
            "env" -> :env
            _ -> :env
          end

        {:locked, until, scope_atom}
    end
  end

  @doc "Failures left for the account before its 5-minute lock."
  def remaining(email, now \\ DateTime.utc_now()) do
    max(@account_max - count(:email, normalize(email), now, @account_window), 0)
  end

  @doc """
  Records a failure (`env` = `%{key:, ip:, user_agent:}`) and locks the account or the
  environment when it reaches its limit.
  """
  def record_failure(email, env, reason, now \\ DateTime.utc_now()) do
    email = normalize(email)
    now = DateTime.truncate(now, :second)

    platform(fn ->
      Repo.insert!(%LoginFailure{
        email: email,
        ip: env[:ip],
        env_key: env[:key],
        user_agent: truncate(env[:user_agent]),
        reason: reason,
        inserted_at: now
      })

      if count(:email, email, now, @account_window) >= @account_max,
        do:
          lock("account", email, now, @account_lock, %{email: email} |> Map.merge(env_info(env)))

      if env[:key] && count(:env_key, env[:key], now, @env_window) >= @env_max,
        do: lock("env", env[:key], now, @env_lock, env_info(env))
    end)

    :ok
  end

  @doc "A successful sign-in: the account's failures no longer count."
  def clear(email) do
    platform(fn ->
      Repo.delete_all(from f in LoginFailure, where: f.email == ^normalize(email))
    end)

    :ok
  end

  @doc "Active locks, newest first, for the admin screen."
  def active_locks(now \\ DateTime.utc_now()) do
    platform(fn ->
      Repo.all(from l in LoginLock, where: l.locked_until > ^now, order_by: [desc: l.id])
    end)
  end

  @doc """
  Lifts a lock (administrator). The failures behind it are forgotten too, or the next
  failure would lock again at once.
  """
  def unlock(lock_id) do
    platform(fn ->
      case Repo.get(LoginLock, lock_id) do
        nil ->
          {:error, :not_found}

        lock ->
          field = if lock.scope == "account", do: :email, else: :env_key
          Repo.delete_all(from f in LoginFailure, where: field(f, ^field) == ^lock.key)

          Repo.delete_all(
            from l in LoginLock, where: l.scope == ^lock.scope and l.key == ^lock.key
          )

          {:ok, lock}
      end
    end)
  end

  @doc """
  The connection environment of a request: the device cookie's id when the browser keeps
  one, else a hash of address, User-Agent and Accept-Language.
  """
  def env_key(device_id, ip, user_agent, accept_language) do
    if is_binary(device_id) and device_id != "" do
      "device:" <> device_id
    else
      digest =
        :crypto.hash(:sha256, Enum.join([ip, user_agent, accept_language], "\n"))
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 22)

      "headers:" <> digest
    end
  end

  @doc "\"Chrome 131 / Windows\" from a User-Agent, for the admin screen."
  def describe_user_agent(nil), do: "不明"

  def describe_user_agent(ua) do
    browser =
      Enum.find_value(
        [
          {~r/Edg\/(\d+)/, "Edge"},
          {~r/OPR\/(\d+)/, "Opera"},
          {~r/Firefox\/(\d+)/, "Firefox"},
          {~r/Chrome\/(\d+)/, "Chrome"},
          {~r/Version\/(\d+)[\d.]* .*Safari/, "Safari"}
        ],
        fn {re, name} ->
          case Regex.run(re, ua) do
            [_, v] -> "#{name} #{v}"
            _ -> nil
          end
        end
      ) || String.slice(ua, 0, 40)

    os =
      cond do
        ua =~ "Windows" -> "Windows"
        ua =~ ~r/iPhone|iPad/ -> "iOS"
        ua =~ "Mac OS X" -> "macOS"
        ua =~ "Android" -> "Android"
        ua =~ "CrOS" -> "ChromeOS"
        ua =~ "Linux" -> "Linux"
        true -> nil
      end

    if os, do: "#{browser} / #{os}", else: browser
  end

  defp lock(scope, key, now, seconds, info) do
    active? =
      Repo.exists?(
        from l in LoginLock, where: l.scope == ^scope and l.key == ^key and l.locked_until > ^now
      )

    unless active? do
      Repo.insert!(
        struct(
          LoginLock,
          Map.merge(info, %{
            scope: scope,
            key: key,
            locked_until: DateTime.add(now, seconds),
            inserted_at: now
          })
        )
      )
    end
  end

  defp env_info(env), do: %{ip: env[:ip], user_agent: truncate(env[:user_agent])}

  defp count(field, value, now, window) do
    since = DateTime.add(now, -window)

    platform(fn ->
      Repo.one(
        from f in LoginFailure,
          where: field(f, ^field) == ^value and f.inserted_at > ^since,
          select: count(f.id)
      )
    end)
  end

  defp platform(fun), do: AskDrive.Apps.platform(fun)
  defp truncate(nil), do: nil
  defp truncate(s), do: String.slice(s, 0, 255)
  defp normalize(email), do: email |> to_string() |> String.trim() |> String.downcase()
end
