defmodule AskDrive.Accounts.LoginThrottle do
  @moduledoc """
  Lockout for password sign-ins (spec 6.13). A password checked against LDAP bypasses
  Google's 2-step verification, so guessing must be slowed down here:

    * per account: 5 failures within 15 minutes lock that account;
    * per source address: 20 failures within 15 minutes lock that address (spraying many
      accounts with one password).

  Failures are rows in the platform DB, so a restart or a new browser doesn't reset them.
  A successful sign-in clears the account's failures.
  """

  import Ecto.Query
  alias AskDrive.Accounts.LoginFailure
  alias AskDrive.Repo

  @window_minutes 15
  @max_per_account 5
  @max_per_ip 20

  def window_minutes, do: @window_minutes
  def max_per_account, do: @max_per_account

  @doc "`:ok`, or `{:locked, until}` (UTC) when the account or the address is locked."
  def check(email, ip, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -@window_minutes * 60)

    [
      locked_until(:email, normalize(email), @max_per_account, since),
      locked_until(:ip, ip, @max_per_ip, since)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> :ok
      untils -> {:locked, Enum.max(untils, DateTime)}
    end
  end

  @doc "Failures left for the account before it locks."
  def remaining(email, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -@window_minutes * 60)
    max(@max_per_account - count(:email, normalize(email), since), 0)
  end

  def record_failure(email, ip, reason) do
    AskDrive.Apps.platform(fn ->
      Repo.insert!(%LoginFailure{email: normalize(email), ip: ip, reason: reason})
    end)

    :ok
  end

  def clear(email) do
    AskDrive.Apps.platform(fn ->
      Repo.delete_all(from f in LoginFailure, where: f.email == ^normalize(email))
    end)

    :ok
  end

  defp locked_until(_field, nil, _max, _since), do: nil
  defp locked_until(_field, "", _max, _since), do: nil

  defp locked_until(field, value, max, since) do
    n = count(field, value, since)

    if n >= max do
      # locked until enough failures leave the window to bring the count below the limit
      pivot =
        AskDrive.Apps.platform(fn ->
          Repo.one(
            from f in LoginFailure,
              where: field(f, ^field) == ^value and f.inserted_at >= ^since,
              order_by: [asc: f.inserted_at, asc: f.id],
              offset: ^(n - max),
              limit: 1,
              select: f.inserted_at
          )
        end)

      DateTime.add(pivot, @window_minutes * 60)
    end
  end

  defp count(field, value, since) do
    AskDrive.Apps.platform(fn ->
      Repo.one(
        from f in LoginFailure,
          where: field(f, ^field) == ^value and f.inserted_at >= ^since,
          select: count(f.id)
      )
    end)
  end

  defp normalize(email), do: email |> to_string() |> String.trim() |> String.downcase()
end
