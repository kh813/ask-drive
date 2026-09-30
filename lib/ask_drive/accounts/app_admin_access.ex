defmodule AskDrive.Accounts.AppAdminAccess do
  @moduledoc """
  An app's own administrator password (spec F-1113).

  An app's admin screen — its Drive settings and API keys — opens only for the people
  assigned to the app (`app_admins`), after entering **the app's password**. Platform
  administrators can't open it: they assign the app's administrators and, in an emergency,
  **reset** (clear) the password; the reset is recorded and shown to the app's
  administrators, and the next of them to come in sets a new one. So the platform
  administrator never knows an app's password.

  The password is required: while it is unset nobody can open the app's admin screen; the
  first assigned administrator to arrive sets it. It is stored as a digest in the app's own
  settings (`app_admin_password_hash`), separate from the platform password (the primary
  app shares its settings row with the platform).

  Elevation is per app: the session keeps, for each app, when and as whom it was elevated
  and a fingerprint of the password, so changing or resetting the password ends every
  session elevated with the old one.
  """
  import Ecto.Query
  alias AskDrive.Accounts
  alias AskDrive.Accounts.{AdminAccess, AdminElevationLog, User}
  alias AskDrive.{Apps, PlatformRepo, Repo, Settings}

  @doc "The app's settings (its own database)."
  def setting(app), do: Apps.with_app(app, &Settings.get_setting!/0)

  def password_set?(app), do: is_binary(setting(app).app_admin_password_hash)

  @doc "Sets the first password; only an assigned administrator, only while unset."
  def set_initial(%User{} = user, app, password, context \\ %{}) do
    cond do
      not Accounts.assigned_app_admin?(user, app.slug) -> {:error, :not_assigned}
      password_set?(app) -> {:error, :already_set}
      true -> store(user, app, password, "password_set", context)
    end
  end

  @doc """
  Elevates `user` for the app. `{:ok, token}` (for the session), or `{:error, reason}`:
  `:not_assigned`, `:no_password`, `{:locked_out, until}`, `:invalid_password`.
  """
  def elevate(%User{} = user, app, password, context \\ %{}) do
    s = setting(app)

    cond do
      not Accounts.assigned_app_admin?(user, app.slug) ->
        {:error, :not_assigned}

      not is_binary(s.app_admin_password_hash) ->
        {:error, :no_password}

      until = locked_out_until(user, app) ->
        log(user, app, "locked_out", context)
        {:error, {:locked_out, until}}

      AdminAccess.password_matches?(s.app_admin_password_hash, password) ->
        log(user, app, "granted", context)
        {:ok, token(user, s)}

      true ->
        log(user, app, "denied", context)
        {:error, :invalid_password}
    end
  end

  @doc "Changes the password; the current one must be given (by an elevated administrator)."
  def change(%User{} = user, app, current, new_password, context \\ %{}) do
    s = setting(app)

    if Accounts.assigned_app_admin?(user, app.slug) and
         AdminAccess.password_matches?(s.app_admin_password_hash, current) do
      store(user, app, new_password, "password_changed", context)
    else
      log(user, app, "denied", context)
      {:error, :invalid_password}
    end
  end

  @doc """
  Clears the password (a platform administrator, in an emergency). Recorded, and shown to
  the app's administrators; the next of them to come in sets a new one.
  """
  def reset(%User{} = actor, app, context \\ %{}) do
    if User.admin_eligible?(actor) do
      Apps.with_app(app, fn ->
        {:ok, _} =
          Settings.get_setting!()
          |> Ecto.Changeset.change(
            app_admin_password_hash: nil,
            app_admin_password_reset_at: now(),
            app_admin_password_reset_by: actor.email
          )
          |> Repo.update()
      end)

      log(actor, app, "password_reset", context)
      :ok
    else
      {:error, :not_authorized}
    end
  end

  @doc "Whether the session token still elevates `user` for the app."
  def elevated?(token, %User{} = user, app) do
    with %{"at" => at, "user" => user_id, "v" => v} <- token,
         true <- user_id == user.id,
         true <- Accounts.assigned_app_admin?(user, app.slug),
         hash when is_binary(hash) <- setting(app).app_admin_password_hash,
         true <- Plug.Crypto.secure_compare(v, fingerprint(hash)) do
      System.system_time(:second) - at < AdminAccess.session_seconds(Settings.platform_setting!())
    else
      _ -> false
    end
  end

  @doc "The session key holding the per-app elevation tokens."
  def session_key, do: "app_admin_elevations"

  defp token(user, s),
    do: %{
      "at" => System.system_time(:second),
      "user" => user.id,
      "v" => fingerprint(s.app_admin_password_hash)
    }

  defp fingerprint(hash),
    do: :crypto.hash(:sha256, hash) |> Base.url_encode64(padding: false) |> binary_part(0, 22)

  defp store(user, app, password, event, context) do
    with :ok <- AdminAccess.validate_password(password) do
      {:ok, _} =
        Apps.with_app(app, fn ->
          Settings.get_setting!()
          |> Ecto.Changeset.change(app_admin_password_hash: AdminAccess.hash_password(password))
          |> Repo.update()
        end)

      log(user, app, event, context)
      :ok
    end
  end

  # Wrong guesses per account and app, with the platform's limits (admin_max_attempts,
  # admin_lockout_minutes)
  defp locked_out_until(user, app) do
    p = Settings.platform_setting!()
    max_attempts = p.admin_max_attempts || 5
    minutes = p.admin_lockout_minutes || 15
    since = DateTime.add(DateTime.utc_now(), -minutes * 60)

    failures =
      PlatformRepo.all(
        from l in AdminElevationLog,
          where:
            l.email == ^user.email and l.app_slug == ^app.slug and l.event == "denied" and
              l.occurred_at >= ^since,
          order_by: [asc: l.occurred_at],
          select: l.occurred_at
      )

    if length(failures) >= max_attempts,
      do: failures |> Enum.at(length(failures) - max_attempts) |> DateTime.add(minutes * 60)
  end

  @doc "Attempts left before the account is locked out of the app."
  def attempts_remaining(user, app) do
    p = Settings.platform_setting!()
    since = DateTime.add(DateTime.utc_now(), -(p.admin_lockout_minutes || 15) * 60)

    failures =
      PlatformRepo.one(
        from l in AdminElevationLog,
          where:
            l.email == ^user.email and l.app_slug == ^app.slug and l.event == "denied" and
              l.occurred_at >= ^since,
          select: count(l.id)
      )

    max((p.admin_max_attempts || 5) - failures, 0)
  end

  defp log(user, app, event, context) do
    %AdminElevationLog{}
    |> AdminElevationLog.changeset(%{
      user_id: user.id,
      email: user.email,
      event: event,
      app_slug: app.slug,
      ip_address: context[:ip_address],
      user_agent: context[:user_agent],
      occurred_at: now()
    })
    |> PlatformRepo.insert()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
