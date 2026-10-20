defmodule AskDrive.Ldap.Directory do
  @moduledoc """
  The Secure LDAP directory's users, fetched once a night, so e-mail fields are completed
  from the platform database instead of a new LDAPS connection on every keystroke (spec
  F-1313; each one took about a second). Only addresses and names are kept.

  The list is fetched in the night window (once a night), when there is none or it is more
  than a day old (at start-up, within a minute; after a failure, again an hour later), and
  from the admin screen (「今すぐ更新」). A fetch replaces the whole list, so people removed
  from the directory drop out of it; a failed one keeps the previous list. It belongs to the
  LDAP settings it was fetched with: once they change, it isn't used until fetched again.

  Someone not on the list (added today) is still found: `AskDrive.Ldap` asks the directory
  when the list has no match.
  """
  require Logger
  import Ecto.Query, warn: false

  alias AskDrive.{Apps, Ldap, Repo, Settings}
  alias AskDrive.Ldap.DirectoryUser
  alias AskDrive.Runtime.Mode

  @topic "ldap_directory"
  @max_age_s 24 * 3600
  @retry_s 3600

  def topic, do: @topic

  @doc "Whether the list can answer for these LDAP settings: fetched, and with them."
  def usable?(setting) do
    setting != nil and setting.ldap_directory_synced_at != nil and
      setting.ldap_directory_fingerprint == Ldap.settings_fingerprint(setting)
  end

  @doc """
  People on the list whose address starts with `q`, or whose name contains it, those whose
  address matches first. `[%{email:, name:}]`.
  """
  def suggest(q, limit \\ 8) do
    q = q |> to_string() |> String.trim() |> String.downcase()
    pattern = escape_like(q)

    Apps.platform(fn ->
      Repo.all(
        from u in DirectoryUser,
          where:
            fragment("? LIKE ? ESCAPE '\\'", u.email, ^"#{pattern}%") or
              fragment("? LIKE ? ESCAPE '\\'", u.name, ^"%#{pattern}%"),
          order_by: [
            asc:
              fragment(
                "CASE WHEN ? LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END",
                u.email,
                ^"#{pattern}%"
              ),
            asc: u.email
          ],
          limit: ^limit,
          select: %{email: u.email, name: u.name}
      )
    end)
  end

  @doc "Whether `email` is on the list."
  def known?(email) do
    email = email |> to_string() |> String.trim() |> String.downcase()
    Apps.platform(fn -> Repo.exists?(from u in DirectoryUser, where: u.email == ^email) end)
  end

  @doc "How many people are on the list."
  def count, do: Apps.platform(fn -> Repo.aggregate(DirectoryUser, :count) end)

  @doc "Whether a fetch is under way."
  def running?, do: Process.whereis(__MODULE__.Fetch) != nil

  @doc """
  Starts a fetch in the background (the admin screen's 「今すぐ更新」); its end is broadcast on
  `topic/0` as `{:ldap_directory, result}`. `{:error, :running}` when one is under way.
  """
  def refresh do
    if running?() do
      {:error, :running}
    else
      Task.start(fn ->
        # two clicks at once: the second one finds the name taken and does nothing
        try do
          Process.register(self(), __MODULE__.Fetch)
        rescue
          ArgumentError -> exit(:normal)
        end

        fetch()
      end)

      :ok
    end
  end

  @doc """
  Fetches the list now (in this process): replaces it on success and records the result on
  the platform setting. `{:ok, count}` or `{:error, message}`.
  """
  def fetch do
    setting = Settings.platform_setting!()
    now = DateTime.utc_now(:second)
    record(%{ldap_directory_checked_at: now})

    result =
      case Ldap.list_people(setting) do
        {:ok, people} ->
          replace(people, now)

          record(%{
            ldap_directory_synced_at: now,
            ldap_directory_error: nil,
            ldap_directory_fingerprint: Ldap.settings_fingerprint(setting)
          })

          Logger.info("LDAP directory: #{length(people)} users fetched (F-1313)")
          {:ok, length(people)}

        {:error, message} ->
          record(%{ldap_directory_error: message})
          Logger.warning("LDAP directory: fetching the users failed: #{message}")
          {:error, message}
      end

    Phoenix.PubSub.broadcast(AskDrive.PubSub, @topic, {:ldap_directory, result})
    result
  rescue
    e ->
      message = Exception.message(e)
      Logger.error("LDAP directory: fetching the users crashed: #{message}")
      record(%{ldap_directory_error: message})
      Phoenix.PubSub.broadcast(AskDrive.PubSub, @topic, {:ldap_directory, {:error, message}})
      {:error, message}
  end

  @doc """
  Whether a fetch is due at `now` (local): LDAP is on, and either tonight's hasn't been tried
  since the night window opened, or the list is missing or more than a day old and the last
  try is more than an hour ago.
  """
  def due?(setting, now \\ AskDrive.Clock.local_now()) do
    utc_now = DateTime.utc_now()

    setting != nil and Ldap.enabled?(setting) and
      ((Mode.calculate_current_mode(now) == :night_batch and
          older?(setting.ldap_directory_checked_at, Mode.night_window_start_utc(now))) or
         (stale?(setting, utc_now) and
            older?(setting.ldap_directory_checked_at, DateTime.add(utc_now, -@retry_s))))
  end

  @doc "Called by the clock every minute: starts a fetch when one is due."
  def maybe_refresh(now \\ AskDrive.Clock.local_now()) do
    if not running?() and due?(Settings.platform_setting(), now), do: refresh()
    :ok
  rescue
    e -> Logger.error("LDAP directory: scheduling crashed: #{Exception.message(e)}")
  end

  defp stale?(setting, utc_now) do
    not usable?(setting) or
      DateTime.diff(utc_now, setting.ldap_directory_synced_at) > @max_age_s
  end

  defp older?(nil, _than), do: true
  defp older?(at, than), do: DateTime.compare(at, than) == :lt

  defp replace(people, now) do
    rows = Enum.map(people, &%{email: &1.email, name: &1.name, inserted_at: now})

    Apps.platform(fn ->
      Repo.transaction(fn ->
        Repo.delete_all(DirectoryUser)
        rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(DirectoryUser, &1))
      end)
    end)
  end

  defp record(attrs) do
    Apps.platform(fn ->
      Settings.get_setting!() |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end)
  end

  defp escape_like(q),
    do:
      q
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")
end
