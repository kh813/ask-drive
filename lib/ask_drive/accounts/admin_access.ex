defmodule AskDrive.Accounts.AdminAccess do
  @moduledoc """
  Administrator elevation: password hashing and verification, attempt throttling, and the
  audit trail (spec 6.9).

  The password is hashed with PBKDF2-HMAC-SHA512 from `:crypto` rather than a dedicated
  password-hashing dependency. It is a single shared operator secret on a LAN-only box, and
  OTP already ships everything needed (N-613).

  Throttling is derived from the audit log instead of session state: an attacker who clears
  their cookies would otherwise reset the counter (N-615).
  """
  import Ecto.Query, warn: false
  require Logger

  alias AskDrive.Accounts.{AdminElevationLog, User}
  alias AskDrive.PlatformRepo
  alias AskDrive.Settings

  @digest :sha512
  @iterations 210_000
  @salt_bytes 16
  @key_bytes 64
  @prefix "pbkdf2-sha512"

  @min_password_length 8

  @doc "Minimum accepted password length."
  def min_password_length, do: @min_password_length

  # --- Hashing --------------------------------------------------------------

  @doc """
  Hashes a password into the `pbkdf2-sha512$iterations$salt$hash` storage format.
  """
  def hash_password(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    hash = :crypto.pbkdf2_hmac(@digest, password, salt, @iterations, @key_bytes)

    Enum.join(
      [@prefix, Integer.to_string(@iterations), Base.encode64(salt), Base.encode64(hash)],
      "$"
    )
  end

  @doc """
  Constant-time comparison of a candidate password against a stored digest (N-614).

  Returns false for any malformed or missing digest rather than raising, so a corrupted
  settings row cannot be turned into an authentication bypass.
  """
  def password_matches?(nil, _password), do: false
  def password_matches?(_stored, nil), do: false

  def password_matches?(stored, password) when is_binary(stored) and is_binary(password) do
    case String.split(stored, "$") do
      [@prefix, iterations, salt_b64, hash_b64] ->
        with {iterations, ""} <- Integer.parse(iterations),
             {:ok, salt} <- Base.decode64(salt_b64),
             {:ok, expected} <- Base.decode64(hash_b64) do
          candidate =
            :crypto.pbkdf2_hmac(@digest, password, salt, iterations, byte_size(expected))

          :crypto.hash_equals(candidate, expected)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  def password_matches?(_stored, _password), do: false

  @doc """
  Whether an administrator password has been configured at all.
  """
  def password_set?(setting \\ nil) do
    case stored_hash(setting) do
      hash when is_binary(hash) and hash != "" -> true
      _ -> false
    end
  end

  # --- Elevation ------------------------------------------------------------

  @doc """
  Attempts to elevate `user` with `password`.

  Returns `{:ok, user}` on success, `{:error, {:locked_out, unlock_at}}` while throttled,
  `{:error, :not_eligible}`, `{:error, :no_password}` or `{:error, :invalid_password}`.
  Every outcome is written to the audit log before returning.
  """
  def elevate(%User{} = user, password, context \\ %{}) do
    setting = Settings.get_setting() || Settings.platform_setting!()
    platform_setting = Settings.platform_setting!()

    cond do
      not password_set?(setting) and not password_set?(platform_setting) ->
        {:error, :no_password}

      true ->
        case locked_out_until(user, platform_setting) do
          nil -> verify_and_elevate(user, password, setting, platform_setting, context)
          unlock_at -> deny_locked_out(user, unlock_at, context)
        end
    end
  end

  defp verify_and_elevate(user, password, setting, platform_setting, context) do
    # App-specific password if set, otherwise fallback to platform admin password
    hash = setting.admin_password_hash || platform_setting.admin_password_hash

    if password_matches?(hash, password) do
      {:ok, user} = touch_elevated_at(user)
      log(user, "granted", context)
      {:ok, user}
    else
      log(user, "denied", context)
      {:error, :invalid_password}
    end
  end

  defp deny_locked_out(user, unlock_at, context) do
    log(user, "locked_out", context)
    {:error, {:locked_out, unlock_at}}
  end

  @doc """
  Records a voluntary release of administrator rights.
  """
  def release(%User{} = user, context \\ %{}) do
    log(user, "released", context)
    :ok
  end

  @doc """
  Records an elevation that lapsed because its time limit passed.
  """
  def record_expiry(%User{} = user, context \\ %{}) do
    log(user, "expired", context)
    :ok
  end

  # --- Access password (合言葉・チャットアクセス制限, spec F-1112) ---

  # An unlocked passphrase is remembered in the session for this long (spec F-1112)
  @access_unlock_days 30

  @doc """
  The session value that remembers an unlocked passphrase: when, and which passphrase (a
  fingerprint of its hash, so changing the passphrase invalidates every unlock).
  """
  def access_unlock_token(%Settings.Setting{} = setting) do
    %{"at" => System.system_time(:second), "v" => access_password_fingerprint(setting)}
  end

  @doc "Whether `token` (from the session) still unlocks the app's current passphrase."
  def access_unlocked?(%{"at" => at, "v" => v}, %Settings.Setting{} = setting)
      when is_integer(at) and is_binary(v) do
    fingerprint = access_password_fingerprint(setting)

    is_binary(fingerprint) and Plug.Crypto.secure_compare(v, fingerprint) and
      System.system_time(:second) - at < @access_unlock_days * 86_400
  end

  def access_unlocked?(_token, _setting), do: false

  defp access_password_fingerprint(%{access_password_hash: hash}) when is_binary(hash) do
    :crypto.hash(:sha256, hash) |> Base.url_encode64(padding: false) |> binary_part(0, 22)
  end

  defp access_password_fingerprint(_), do: nil

  @doc """
  Verifies if candidate password matches the app access password.
  """
  def verify_access_password(candidate, %Settings.Setting{} = setting) do
    if setting.access_password_enabled and is_binary(setting.access_password_hash) do
      password_matches?(setting.access_password_hash, candidate)
    else
      true
    end
  end

  @doc """
  Sets or updates the app access password.
  """
  def set_access_password(%Settings.Setting{} = setting, password) when is_binary(password) do
    with :ok <- validate_password(password) do
      setting
      |> Ecto.Changeset.change(%{
        access_password_hash: hash_password(password),
        access_password_enabled: true
      })
      |> AskDrive.Repo.update()
    end
  end

  @doc """
  Disables the app access password.
  """
  def disable_access_password(%Settings.Setting{} = setting) do
    setting
    |> Ecto.Changeset.change(%{access_password_enabled: false})
    |> AskDrive.Repo.update()
  end

  @doc """
  How long an elevated session stays valid, in seconds.
  """
  def session_seconds(setting \\ nil) do
    setting = resolve_setting(setting)
    minutes = (setting && setting.admin_session_minutes) || 30
    max(minutes, 1) * 60
  end

  # --- Throttling -----------------------------------------------------------

  @doc """
  Returns the `DateTime` the user may try again, or nil when they are not throttled.
  """
  def locked_out_until(%User{} = user, setting \\ nil) do
    setting = resolve_setting(setting)
    max_attempts = (setting && setting.admin_max_attempts) || 5
    lockout_minutes = (setting && setting.admin_lockout_minutes) || 15
    window_start = DateTime.add(DateTime.utc_now(), -lockout_minutes * 60, :second)

    failures =
      PlatformRepo.all(
        from l in AdminElevationLog,
          where:
            l.email == ^user.email and l.event == "denied" and l.occurred_at >= ^window_start,
          order_by: [asc: l.occurred_at],
          select: l.occurred_at
      )

    if length(failures) >= max_attempts do
      failures
      |> List.first()
      |> DateTime.add(lockout_minutes * 60, :second)
    end
  end

  @doc """
  Attempts remaining before the user is locked out.
  """
  def attempts_remaining(%User{} = user, setting \\ nil) do
    setting = resolve_setting(setting)
    max_attempts = (setting && setting.admin_max_attempts) || 5
    lockout_minutes = (setting && setting.admin_lockout_minutes) || 15
    window_start = DateTime.add(DateTime.utc_now(), -lockout_minutes * 60, :second)

    failures =
      PlatformRepo.one(
        from l in AdminElevationLog,
          where:
            l.email == ^user.email and l.event == "denied" and l.occurred_at >= ^window_start,
          select: count(l.id)
      ) || 0

    max(max_attempts - failures, 0)
  end

  # --- Password management --------------------------------------------------

  @doc """
  Sets the first administrator password. Refuses if one already exists (F-917).
  """
  def set_initial_password(%User{} = user, password, context \\ %{}) do
    setting = Settings.platform_setting!()

    cond do
      password_set?(setting) -> {:error, :already_set}
      not User.admin_eligible?(user) -> {:error, :not_eligible}
      true -> store_password(setting, password, user, "password_set", context)
    end
  end

  @doc """
  Changes the administrator password. The current password must be supplied (F-914).
  Supports passing an app-specific setting struct.
  """
  def change_password(
        %User{} = user,
        current_password,
        new_password,
        context \\ %{},
        setting \\ nil
      ) do
    target_setting = setting || Settings.get_setting() || Settings.platform_setting!()
    platform_setting = Settings.platform_setting!()
    current_hash = target_setting.admin_password_hash || platform_setting.admin_password_hash

    # Platform super admin can change with either current password or platform admin password
    if password_matches?(current_hash, current_password) or
         (User.admin_eligible?(user) and
            password_matches?(platform_setting.admin_password_hash, current_password)) do
      store_password(target_setting, new_password, user, "password_changed", context)
    else
      log(user, "denied", context)
      {:error, :invalid_password}
    end
  end

  @doc """
  Resets the admin password for an app (called by Super Admin).
  """
  def reset_app_admin_password(
        %User{} = actor,
        %AskDrive.Apps.App{} = app,
        new_password,
        context \\ %{}
      ) do
    if User.admin_eligible?(actor) do
      AskDrive.Apps.with_app(app, fn ->
        setting = Settings.get_setting!()

        with :ok <- validate_password(new_password),
             {:ok, updated} <-
               setting
               |> Ecto.Changeset.change(admin_password_hash: hash_password(new_password))
               |> AskDrive.Repo.update() do
          log(actor, "password_changed", context)
          {:ok, updated}
        end
      end)
    else
      {:error, :not_authorized}
    end
  end

  @doc """
  Sets the password with no current-password check. Only for the CLI recovery path (F-920).
  """
  def force_set_password(password) do
    setting = Settings.platform_setting!()

    with :ok <- validate_password(password) do
      setting
      |> Ecto.Changeset.change(admin_password_hash: hash_password(password))
      |> PlatformRepo.update()
    end
  end

  defp store_password(setting, password, user, event, context) do
    with :ok <- validate_password(password),
         {:ok, updated} <-
           setting
           |> Ecto.Changeset.change(admin_password_hash: hash_password(password))
           |> AskDrive.Repo.update() do
      log(user, event, context)
      {:ok, updated}
    end
  end

  defp validate_password(password) when is_binary(password) do
    trimmed = String.trim(password)

    cond do
      String.length(trimmed) < @min_password_length ->
        {:error, :too_short}

      trimmed != password ->
        {:error, :surrounding_whitespace}

      true ->
        :ok
    end
  end

  defp validate_password(_), do: {:error, :too_short}

  # --- Audit log ------------------------------------------------------------

  @doc """
  Most recent audit entries, newest first.
  """
  def list_elevation_logs(limit \\ 100) do
    PlatformRepo.all(
      from l in AdminElevationLog,
        order_by: [desc: l.occurred_at, desc: l.id],
        limit: ^limit,
        preload: [:user]
    )
  end

  @doc """
  Appends an audit entry. Never receives or stores the password itself (N-606).
  """
  def log(%User{} = user, event, context \\ %{}) do
    %AdminElevationLog{}
    |> AdminElevationLog.changeset(%{
      user_id: user.id,
      email: user.email,
      event: event,
      ip_address: context[:ip_address],
      user_agent: context[:user_agent],
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> PlatformRepo.insert()
    |> case do
      {:ok, entry} ->
        {:ok, entry}

      {:error, changeset} ->
        # Losing an audit row must not take the request down with it, but it should be loud.
        Logger.error("Failed to write admin elevation log: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp touch_elevated_at(user) do
    user
    |> User.changeset(%{last_elevated_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> PlatformRepo.update()
  end

  defp stored_hash(setting) do
    case resolve_setting(setting) do
      %{admin_password_hash: hash} -> hash
      _ -> nil
    end
  end

  defp resolve_setting(%{__struct__: _} = setting), do: setting

  defp resolve_setting(_) do
    Settings.platform_setting()
  rescue
    _ -> nil
  end
end
