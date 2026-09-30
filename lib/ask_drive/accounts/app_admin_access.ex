defmodule AskDrive.Accounts.AppAdminAccess do
  @moduledoc """
  Who administers an app, and getting into its admin screen (spec F-1113, F-1114).

  An app's admin screen — its Drive settings and API keys — is for the people assigned to
  the app (`app_admins`), each with their own account. There is no shared app password:
  to come in, an administrator confirms it is really them —

    * with their own password, checked by Secure LDAP, when LDAP sign-in is on;
    * otherwise by having signed in within the last 10 minutes (signing in again if not).

  Platform administrators don't get in unless assigned. Every app has at least one
  administrator (named when the app is created); its administrators add others and may
  remove themselves as long as someone remains. Platform administrators can change the
  assignment too, to recover an app whose administrators have all left — recorded, and
  shown to the app's administrators.

  Elevation is per app: the session keeps, for each app, when and as whom it was elevated.
  Removing someone ends their access at their next request.
  """
  import Ecto.Query
  alias AskDrive.Accounts
  alias AskDrive.Accounts.{AdminAccess, AdminElevationLog, LoginThrottle, User}
  alias AskDrive.{Ldap, PlatformRepo, Settings}

  @fresh_login_seconds 10 * 60

  def fresh_login_minutes, do: div(@fresh_login_seconds, 60)

  @doc "How an administrator confirms it is them: `:ldap_password` or `:fresh_login`."
  def confirmation_method do
    if Ldap.enabled?(Settings.platform_setting!()), do: :ldap_password, else: :fresh_login
  end

  @doc """
  Elevates with the administrator's own password (Secure LDAP). `env` is the connection
  environment for the sign-in lockout (F-1305), which wrong passwords count towards.
  `{:ok, token}` or `{:error, :not_assigned | {:locked, until} | :invalid_password |
  {:unavailable, message}}`.
  """
  def elevate_with_password(%User{} = user, app, password, env, context \\ %{}) do
    cond do
      not Accounts.assigned_app_admin?(user, app.slug) ->
        {:error, :not_assigned}

      match?({:locked, _, _}, LoginThrottle.check(user.email, env.key)) ->
        {:locked, until, _} = LoginThrottle.check(user.email, env.key)
        log(user, app, "locked_out", context)
        {:error, {:locked, until}}

      true ->
        case Ldap.authenticate(Settings.platform_setting!(), user.email, password) do
          {:ok, _} ->
            LoginThrottle.clear(user.email)
            log(user, app, "granted", context)
            {:ok, token(user)}

          {:error, :invalid_credentials} ->
            LoginThrottle.record_failure(user.email, env, "app_admin_password")
            log(user, app, "denied", context)
            {:error, :invalid_password}

          {:error, {:unavailable, message}} ->
            {:error, {:unavailable, message}}
        end
    end
  end

  @doc "Elevates without a password when the sign-in (unix seconds) is recent enough."
  def elevate_with_fresh_login(%User{} = user, app, authenticated_at, context \\ %{}) do
    cond do
      not Accounts.assigned_app_admin?(user, app.slug) ->
        {:error, :not_assigned}

      is_integer(authenticated_at) and
          System.system_time(:second) - authenticated_at <= @fresh_login_seconds ->
        log(user, app, "granted", context)
        {:ok, token(user)}

      true ->
        {:error, :stale_login}
    end
  end

  @doc "Whether the session token still elevates `user` for the app."
  def elevated?(%{"at" => at, "user" => user_id}, %User{id: user_id} = user, app)
      when is_integer(at) do
    Accounts.assigned_app_admin?(user, app.slug) and
      System.system_time(:second) - at < AdminAccess.session_seconds(Settings.platform_setting!())
  end

  def elevated?(_token, _user, _app), do: false

  @doc "The session key holding the per-app elevation tokens."
  def session_key, do: "app_admin_elevations"

  defp token(user), do: %{"at" => System.system_time(:second), "user" => user.id}

  # --- Administrators --------------------------------------------------------------

  def admins(app), do: Accounts.list_app_admins(app.slug)

  @doc """
  Adds administrators by e-mail (creating accounts that have never signed in). `actor` is
  an administrator of the app, or a platform administrator (recovery).
  """
  def add_admins(%User{} = actor, app, emails, context \\ %{}) do
    if may_manage?(actor, app) do
      for email <- emails do
        {:ok, user} = Accounts.ensure_user(email)

        unless Accounts.assigned_app_admin?(user, app.slug) do
          {:ok, _} = Accounts.add_app_admin(user, app.slug)
          log(actor, app, "app_admin_added", Map.put(context, :target_email, user.email))
        end
      end

      :ok
    else
      {:error, :not_authorized}
    end
  end

  @doc "Removes an administrator — oneself included — unless they are the last one."
  def remove_admin(%User{} = actor, app, %User{} = user, context \\ %{}) do
    cond do
      not may_manage?(actor, app) ->
        {:error, :not_authorized}

      not Accounts.assigned_app_admin?(user, app.slug) ->
        :ok

      length(admins(app)) <= 1 ->
        {:error, :last_admin}

      true ->
        {:ok, _} = Accounts.remove_app_admin(user, app.slug)
        log(actor, app, "app_admin_removed", Map.put(context, :target_email, user.email))
        :ok
    end
  end

  defp may_manage?(actor, app),
    do: Accounts.assigned_app_admin?(actor, app.slug) or User.admin_eligible?(actor)

  @doc """
  Recent changes to the app's administrators, newest first:
  `%{at:, event:, actor:, target:, by_platform?:}` (by_platform? = the actor wasn't one of
  the app's administrators then — a platform administrator recovering the app).
  """
  def admin_changes(app, limit \\ 20) do
    PlatformRepo.all(
      from l in AdminElevationLog,
        where: l.app_slug == ^app.slug and l.event in ["app_admin_added", "app_admin_removed"],
        order_by: [desc: l.occurred_at, desc: l.id],
        limit: ^limit
    )
    |> Enum.map(fn l ->
      %{
        at: l.occurred_at,
        event: l.event,
        actor: l.email,
        target: l.target_email,
        by_platform?: l.user_agent == "platform-admin"
      }
    end)
  end

  defp log(user, app, event, context) do
    %AdminElevationLog{}
    |> AdminElevationLog.changeset(%{
      # the POC guest (id 0) isn't a stored user
      user_id: if(user.id == 0, do: nil, else: user.id),
      email: user.email,
      event: event,
      app_slug: app.slug,
      target_email: context[:target_email],
      ip_address: context[:ip_address],
      # marks a change made by a platform administrator who isn't one of the app's (recovery)
      user_agent:
        if(
          event in ["app_admin_added", "app_admin_removed"] and
            not Accounts.assigned_app_admin?(user, app.slug) and User.admin_eligible?(user),
          do: "platform-admin",
          else: context[:user_agent]
        ),
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> PlatformRepo.insert()
  end
end
