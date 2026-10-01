defmodule AskDrive.Accounts.AdminAccess do
  @moduledoc """
  Platform administrator elevation and its audit trail (spec 6.9), plus the password
  hashing the desks' passphrases use (F-1112).

  There is no shared administrator password. A platform administrator (`admin_eligible`)
  confirms it is really them, the same way a desk's administrators do (F-1113):

    * with their own password, checked by Secure LDAP, when LDAP sign-in is on — wrong
      passwords count towards the sign-in lockout (F-1305);
    * otherwise by having signed in within the last 10 minutes (signing in again if not).

  Passwords are hashed with PBKDF2-HMAC-SHA512 from `:crypto`; OTP already ships
  everything needed (N-613).
  """
  import Ecto.Query, warn: false
  require Logger

  alias AskDrive.Accounts.{AdminElevationLog, AppAdminAccess, LoginThrottle, User}
  alias AskDrive.{Ldap, PlatformRepo, Settings}

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

  # --- Elevation ------------------------------------------------------------

  @doc "How an administrator confirms it is them: `:ldap_password` or `:fresh_login`."
  defdelegate confirmation_method, to: AppAdminAccess

  @doc """
  Elevates a platform administrator with their own password (Secure LDAP). `env` is the
  connection environment for the sign-in lockout. `{:ok, user}` or `{:error, :not_eligible
  | {:locked, until} | :invalid_password | {:unavailable, message}}`. Every outcome but an
  unreachable LDAP server is written to the audit log.
  """
  def elevate_with_password(%User{} = user, password, env, context \\ %{}) do
    cond do
      not User.admin_eligible?(user) ->
        {:error, :not_eligible}

      match?({:locked, _, _}, LoginThrottle.check(user.email, env.key)) ->
        {:locked, until, _} = LoginThrottle.check(user.email, env.key)
        log(user, "locked_out", context)
        {:error, {:locked, until}}

      true ->
        case Ldap.authenticate(Settings.platform_setting!(), user.email, password) do
          {:ok, _} ->
            LoginThrottle.clear(user.email)
            grant(user, context)

          {:error, :invalid_credentials} ->
            LoginThrottle.record_failure(user.email, env, "admin_password")
            log(user, "denied", context)
            {:error, :invalid_password}

          {:error, {:unavailable, message}} ->
            {:error, {:unavailable, message}}
        end
    end
  end

  @doc """
  Elevates a platform administrator without a password when the sign-in (unix seconds) is
  recent enough: `{:ok, user}` or `{:error, :not_eligible | :stale_login}`.
  """
  def elevate_with_fresh_login(%User{} = user, authenticated_at, context \\ %{}) do
    cond do
      not User.admin_eligible?(user) ->
        {:error, :not_eligible}

      is_integer(authenticated_at) and
          System.system_time(:second) - authenticated_at <=
            AppAdminAccess.fresh_login_minutes() * 60 ->
        grant(user, context)

      true ->
        {:error, :stale_login}
    end
  end

  defp grant(user, context) do
    {:ok, user} = touch_elevated_at(user)
    log(user, "granted", context)
    {:ok, user}
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

  # --- Password rules (the desks' passphrases) ------------------------------------

  @doc "Minimum length, no surrounding whitespace: `:ok` or `{:error, reason}`."
  def validate_password(password) when is_binary(password) do
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

  def validate_password(_), do: {:error, :too_short}

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

  defp resolve_setting(%{__struct__: _} = setting), do: setting

  defp resolve_setting(_) do
    Settings.platform_setting()
  rescue
    _ -> nil
  end
end
