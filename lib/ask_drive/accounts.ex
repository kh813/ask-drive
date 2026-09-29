defmodule AskDrive.Accounts do
  @moduledoc """
  Two kinds of account live here (spec 6.9):

    * `AskDrive.Accounts.GoogleAccount` — the singleton Drive-reading service account,
      whose OAuth tokens are stored and refreshed for the nightly batch. This is only used
      when `settings.drive_auth_mode == "oauth"` (the default); in `"service_account"` mode,
      `AskDrive.Drive.ServiceAccount` mints tokens directly from the stored JSON key instead,
      and no row here is ever created.
    * `AskDrive.Accounts.User` — the people who sign in, with an `admin` / `user` role.
      No tokens are kept; sign-in only establishes identity.
  """
  import Ecto.Query, warn: false

  alias AskDrive.Accounts.{AppAdmin, GoogleAccount, User}
  alias AskDrive.Drive.{OAuth, ServiceAccount}
  alias AskDrive.Repo
  alias AskDrive.Settings

  @doc """
  Gets the connected Google account (singleton), or nil if not connected.
  """
  def get_account do
    Repo.one(from a in GoogleAccount, limit: 1)
  end

  @doc """
  Saves or updates the singleton Google account tokens.
  """
  def save_tokens(attrs) do
    expires_in = attrs[:expires_in] || attrs["expires_in"] || 3600
    expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

    params = %{
      email: attrs[:email] || attrs["email"],
      access_token: attrs[:access_token] || attrs["access_token"],
      refresh_token: attrs[:refresh_token] || attrs["refresh_token"],
      token_expires_at: expires_at,
      scope: attrs[:scope] || attrs["scope"],
      status: "connected"
    }

    case get_account() do
      nil ->
        %GoogleAccount{}
        |> GoogleAccount.changeset(params)
        |> Repo.insert()

      account ->
        # If refresh_token is nil in new params, preserve existing
        params =
          if is_nil(params.refresh_token) do
            Map.delete(params, :refresh_token)
          else
            params
          end

        account
        |> GoogleAccount.changeset(params)
        |> Repo.update()
    end
  end

  @doc """
  Retrieves a valid Drive access token, however Drive access is currently authenticated.

  In `"oauth"` mode (the default) this refreshes the stored OAuth token when it expires
  within 120 seconds. In `"service_account"` mode it mints (and caches) a token directly
  from the stored JSON key via `AskDrive.Drive.ServiceAccount` — no `google_accounts` row is
  involved at all.
  """
  def get_valid_access_token do
    case Settings.get_setting() do
      %{drive_auth_mode: "service_account", drive_service_account_json: json} = setting
      when is_binary(json) and json != "" ->
        ServiceAccount.get_valid_access_token(json, setting.drive_impersonate_email)

      %{drive_auth_mode: "service_account"} ->
        {:error, :service_account_not_configured}

      _oauth_or_unconfigured ->
        get_oauth_access_token()
    end
  end

  defp get_oauth_access_token do
    case get_account() do
      nil ->
        {:error, :not_connected}

      %GoogleAccount{status: "invalid_grant"} ->
        {:error, :invalid_grant}

      %GoogleAccount{refresh_token: nil} ->
        {:error, :missing_refresh_token}

      %GoogleAccount{} = account ->
        now = DateTime.utc_now()
        # Refresh if expires in less than 120 seconds
        needs_refresh =
          is_nil(account.token_expires_at) or
            DateTime.diff(account.token_expires_at, now, :second) < 120

        if needs_refresh do
          refresh_account_token(account)
        else
          {:ok, account.access_token}
        end
    end
  end

  @doc """
  Refreshes account token and updates database.
  """
  def refresh_account_token(%GoogleAccount{} = account) do
    case OAuth.refresh_token(account.refresh_token) do
      {:ok, tokens} ->
        {:ok, updated_account} = save_tokens(tokens)
        {:ok, updated_account.access_token}

      {:error, :invalid_grant} ->
        account
        |> GoogleAccount.changeset(%{status: "invalid_grant"})
        |> Repo.update()

        {:error, :invalid_grant}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether Drive sync currently has usable credentials, regardless of which authentication
  mode is active. Chat/admin banners key off this instead of `get_account/0` directly, since
  that returns nil in service-account mode even when everything is configured correctly.
  """
  def drive_connected? do
    case Settings.get_setting() do
      %{drive_auth_mode: "service_account", drive_service_account_json: json} ->
        is_binary(json) and json != ""

      _oauth_or_unconfigured ->
        not is_nil(get_account())
    end
  end

  @doc """
  A short, human-readable identifier for whichever Drive credential is active — the OAuth
  account's email, or the service account's email parsed from its JSON key — for display in
  the admin dashboard. Returns nil when nothing is configured.
  """
  def drive_identity do
    case Settings.get_setting() do
      %{drive_auth_mode: "service_account", drive_service_account_json: json} = setting
      when is_binary(json) and json != "" ->
        case {ServiceAccount.parse(json), setting.drive_impersonate_email} do
          {{:ok, _}, subject} when is_binary(subject) and subject != "" ->
            "#{subject}（サービスアカウントによる委任）"

          {{:ok, %{client_email: email}}, _} ->
            email

          {{:error, _}, _} ->
            nil
        end

      _oauth_or_unconfigured ->
        case get_account() do
          %GoogleAccount{email: email} -> email
          nil -> nil
        end
    end
  end

  @doc """
  Disconnects Google account and clears credentials.
  """
  def disconnect_account do
    case get_account() do
      nil ->
        :ok

      account ->
        if account.refresh_token do
          OAuth.revoke(account.refresh_token)
        end

        Repo.delete(account)
        :ok
    end
  end

  @doc """
  Removes the stored service account key. The counterpart to `disconnect_account/0` for
  `"service_account"` mode.
  """
  def disconnect_service_account do
    Settings.get_setting!()
    |> Ecto.Changeset.change(drive_service_account_json: nil)
    |> Repo.update()

    :ok
  end

  # --- Users (spec 6.9) -----------------------------------------------------
  #
  # Users are platform-wide (spec 6.11): whichever app a process is serving, they live in the
  # platform database, so every query in this section goes through `on_platform/1`.

  defp on_platform(fun), do: AskDrive.Apps.platform(fun)

  @doc """
  Fetches a user by id, or nil.
  """
  def get_user(nil), do: nil
  def get_user(id), do: on_platform(fn -> Repo.get(User, id) end)

  @doc """
  Fetches a user by email address (case-insensitive), or nil.
  """
  def get_user_by_email(email) when is_binary(email) do
    on_platform(fn -> Repo.get_by(User, email: User.normalize_email(email)) end)
  end

  def get_user_by_email(_), do: nil

  @doc """
  All users, elevation-eligible accounts first and then alphabetically by email.
  Preloads associated `app_admins`.
  """
  def list_users do
    on_platform(fn ->
      Repo.all(
        from u in User,
          order_by: [desc: u.admin_eligible, asc: u.email],
          preload: [:app_admins]
      )
    end)
  end

  @doc """
  Number of accounts that can still elevate to administrator.
  """
  def count_eligible_admins do
    on_platform(fn ->
      Repo.one(
        from u in User,
          where: u.admin_eligible == true and u.status == "active",
          select: count(u.id)
      )
    end) || 0
  end

  @doc """
  Email addresses that are always allowed to elevate, from `ASK_DRIVE_ADMIN_EMAILS`
  (F-915). Set during initial setup so the first sign-in can reach the admin screen.
  """
  def configured_admin_emails do
    (System.get_env("ASK_DRIVE_ADMIN_EMAILS") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&User.normalize_email/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Creates or refreshes a user from a successful Google sign-in.

  Everyone starts as a plain user; `admin_eligible` only decides whether they may later
  enter the administrator password (spec 6.9.1).

  Returns `{:error, :disabled}` for a deactivated account so the caller can explain why the
  sign-in was refused rather than silently creating a session (F-918).
  """
  def upsert_user_from_login(attrs) do
    email = User.normalize_email(attrs[:email] || attrs["email"] || "")
    existing = get_user_by_email(email)

    if existing && not User.active?(existing) do
      {:error, :disabled}
    else
      params = %{
        email: email,
        name: attrs[:name] || attrs["name"],
        picture_url: attrs[:picture] || attrs["picture"] || (existing && existing.picture_url),
        admin_eligible: resolve_eligibility(email, existing),
        status: "active",
        last_login_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      case existing do
        nil -> on_platform(fn -> %User{} |> User.changeset(params) |> Repo.insert() end)
        user -> on_platform(fn -> user |> User.changeset(params) |> Repo.update() end)
      end
    end
  end

  # Addresses listed in the environment are always eligible. Otherwise an existing user
  # keeps whatever an administrator set, and the very first person to sign in on a fresh
  # install becomes eligible so the system is never left unmanageable (F-916).
  defp resolve_eligibility(email, existing) do
    cond do
      email in configured_admin_emails() -> true
      existing -> existing.admin_eligible
      count_eligible_admins() == 0 -> true
      true -> false
    end
  end

  @doc """
  Grants or revokes the ability to elevate. `actor` is the administrator making the change.

  Refuses to revoke the actor's own eligibility or the last remaining one, which would
  leave nobody able to reach the settings screen (F-913).
  """
  def set_admin_eligible(%User{} = actor, %User{} = user, eligible) when is_boolean(eligible) do
    with :ok <- ensure_not_self(actor, user),
         :ok <- ensure_eligible_remains(user, eligible, user.status) do
      on_platform(fn -> user |> User.changeset(%{admin_eligible: eligible}) |> Repo.update() end)
    end
  end

  @doc """
  Activates or deactivates a user, with the same last-eligible-account protection as
  `set_admin_eligible/3`.
  """
  def update_user_status(%User{} = actor, %User{} = user, status) do
    with :ok <- ensure_not_self(actor, user),
         :ok <- ensure_eligible_remains(user, user.admin_eligible, status) do
      on_platform(fn -> user |> User.changeset(%{status: status}) |> Repo.update() end)
    end
  end

  @doc """
  Marks an address as able to elevate from outside the web UI, creating the user if needed.

  This is the documented recovery path when nobody can reach the admin screen (F-920); it
  deliberately skips the protections above because there is nobody left to protect. It
  grants no rights on its own — the account still has to sign in and enter the password.
  """
  def grant_admin(email) when is_binary(email) do
    email = User.normalize_email(email)

    case get_user_by_email(email) do
      nil ->
        on_platform(fn ->
          %User{}
          |> User.changeset(%{email: email, admin_eligible: true, status: "active"})
          |> Repo.insert()
        end)

      user ->
        on_platform(fn ->
          user
          |> User.changeset(%{admin_eligible: true, status: "active"})
          |> Repo.update()
        end)
    end
  end

  # --- App Admins (spec 6.11 F-1110) ----------------------------------------

  @doc """
  Returns all app slugs a user is authorized to administer.
  """
  def list_user_app_slugs(%User{id: user_id}) do
    on_platform(fn ->
      Repo.all(from aa in AppAdmin, where: aa.user_id == ^user_id, select: aa.app_slug)
    end)
  end

  def list_user_app_slugs(_), do: []

  @doc """
  Checks if a user is authorized to administer a specific app.
  Global elevation-eligible admins can administer all apps.
  App admins can administer their assigned app(s).
  """
  def app_admin_eligible?(%User{status: "active"} = user, app_slug) when is_binary(app_slug) do
    if User.admin_eligible?(user) do
      true
    else
      normalized_slug = String.trim(String.downcase(app_slug))

      on_platform(fn ->
        Repo.exists?(
          from aa in AppAdmin,
            where: aa.user_id == ^user.id and aa.app_slug == ^normalized_slug
        )
      end)
    end
  end

  def app_admin_eligible?(_, _), do: false

  @doc """
  Checks if a user can elevate to ANY administration role (platform or at least one app).
  """
  def any_admin_eligible?(%User{status: "active"} = user) do
    if User.admin_eligible?(user) do
      true
    else
      on_platform(fn ->
        Repo.exists?(from aa in AppAdmin, where: aa.user_id == ^user.id)
      end)
    end
  end

  def any_admin_eligible?(_), do: false

  @doc """
  Assigns a user as admin of a specific app.
  """
  def add_app_admin(%User{} = user, app_slug) when is_binary(app_slug) do
    slug = String.trim(String.downcase(app_slug))

    on_platform(fn ->
      case Repo.get_by(AppAdmin, user_id: user.id, app_slug: slug) do
        nil ->
          %AppAdmin{}
          |> AppAdmin.changeset(%{user_id: user.id, app_slug: slug})
          |> Repo.insert()

        existing ->
          {:ok, existing}
      end
    end)
  end

  @doc """
  Revokes app admin rights for a specific user and app.
  """
  def remove_app_admin(%User{} = user, app_slug) when is_binary(app_slug) do
    slug = String.trim(String.downcase(app_slug))

    on_platform(fn ->
      case Repo.get_by(AppAdmin, user_id: user.id, app_slug: slug) do
        nil -> :ok
        app_admin -> Repo.delete(app_admin)
      end
    end)
  end

  @doc """
  Sets the full list of apps a user is allowed to administer.
  """
  def set_user_apps(%User{} = user, app_slugs) when is_list(app_slugs) do
    target_slugs =
      app_slugs
      |> Enum.map(&String.trim(String.downcase(&1)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    on_platform(fn ->
      current = Repo.all(from aa in AppAdmin, where: aa.user_id == ^user.id)
      current_slugs = Enum.map(current, & &1.app_slug)

      to_remove = Enum.filter(current, &(&1.app_slug not in target_slugs))
      to_add = target_slugs -- current_slugs

      Enum.each(to_remove, &Repo.delete/1)

      Enum.each(to_add, fn slug ->
        %AppAdmin{}
        |> AppAdmin.changeset(%{user_id: user.id, app_slug: slug})
        |> Repo.insert!()
      end)

      :ok
    end)
  end

  defp ensure_not_self(%User{id: id}, %User{id: id}), do: {:error, :cannot_modify_self}
  defp ensure_not_self(_actor, _user), do: :ok

  defp ensure_eligible_remains(%User{admin_eligible: true, status: "active"}, eligible, status) do
    still_eligible? = eligible and status == "active"

    if still_eligible? or count_eligible_admins() > 1 do
      :ok
    else
      {:error, :last_admin}
    end
  end

  defp ensure_eligible_remains(_user, _eligible, _status), do: :ok
end
