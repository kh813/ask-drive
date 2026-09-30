defmodule AskDrive.Setup do
  @moduledoc """
  First-access web setup (spec 6.12).

  `app.sh setup` no longer asks for the administrator password or the Google Workspace
  domain; the first visit to the web UI does, at `/setup`. Because "whoever gets there first
  becomes the administrator" is unsafe on a shared LAN (and more so once the site is public),
  setup requires a one-time **setup code** that only someone with access to the server can
  read: it is printed in the server log at boot, shown by `./app.sh status`, and stored in
  `setup_code` (mode 0600) next to the platform database. Wrong codes are rate limited;
  completing setup deletes the code.

  Setup is required while the platform has no `setup_completed_at` — unless an installation
  from before this existed already has both an administrator password and a domain, in which
  case it is simply marked complete.
  """
  require Logger

  alias AskDrive.Accounts.AdminAccess
  alias AskDrive.{Apps, PlatformRepo, Settings}

  @max_failures 10
  @lockout_seconds 15 * 60
  @table __MODULE__

  # --- State --------------------------------------------------------------------

  @doc "Whether the first-access setup still has to be done (cached once complete)."
  def required? do
    cond do
      not Application.get_env(:ask_drive, :setup_check, true) -> false
      :persistent_term.get({__MODULE__, :done}, false) -> false
      true -> check_required()
    end
  end

  defp check_required do
    setting = Settings.platform_setting!()

    cond do
      setting.setup_completed_at ->
        mark_done()
        false

      # configured before web setup existed: nothing to ask
      AdminAccess.password_set?(setting) and present?(setting.allowed_domain) ->
        {:ok, _} = complete!(setting)
        false

      true ->
        true
    end
  rescue
    # database not ready (very early boot): don't block requests on it
    _ -> false
  end

  defp mark_done, do: :persistent_term.put({__MODULE__, :done}, true)

  @doc "Forgets the cached state (tests)."
  def reset_cache, do: :persistent_term.erase({__MODULE__, :done})

  # --- Setup code -------------------------------------------------------------------

  def code_path do
    dir =
      Application.get_env(:ask_drive, :setup_dir) ||
        Path.dirname(AskDrive.Repo.config()[:database] || Path.expand("ask_drive.db"))

    Path.join(dir, "setup_code")
  end

  @doc """
  At boot: if setup is required, make sure a code exists and print it. Returns the code or nil.
  """
  def prepare do
    if required?() do
      code = ensure_code()

      Logger.warning("""
      AskDrive の初回セットアップが必要です。ブラウザで AskDrive を開き、次のセットアップコードを入力してください。
        セットアップコード: #{code}
      （./app.sh status でも確認できます。ファイル: #{code_path()}）\
      """)

      code
    end
  end

  @doc "The current setup code, creating one if needed."
  def ensure_code do
    case File.read(code_path()) do
      {:ok, code} when byte_size(code) > 0 ->
        String.trim(code)

      _ ->
        code = generate_code()
        File.mkdir_p!(Path.dirname(code_path()))
        File.write!(code_path(), code <> "\n")
        File.chmod!(code_path(), 0o600)
        code
    end
  end

  # 12 characters from an alphabet without look-alikes, grouped: "K7QX-M4PD-9HTA"
  @alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  defp generate_code do
    for(_ <- 1..12, do: Enum.random(@alphabet))
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &to_string/1)
  end

  @doc """
  Checks a submitted code (case, spaces and dashes ignored). After #{@max_failures} wrong
  codes further attempts are refused for #{div(@lockout_seconds, 60)} minutes.
  """
  def verify_code(submitted) do
    ensure_table()
    now = System.system_time(:second)

    case :ets.lookup(@table, :failures) do
      [{:failures, n, since}] when n >= @max_failures and now - since < @lockout_seconds ->
        {:error, :locked}

      _ ->
        expected = normalize(ensure_code())

        if Plug.Crypto.secure_compare(normalize(submitted || ""), expected) do
          :ets.delete(@table, :failures)
          :ok
        else
          record_failure(now)
          {:error, :invalid}
        end
    end
  end

  defp normalize(code), do: code |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")

  defp record_failure(now) do
    case :ets.lookup(@table, :failures) do
      [{:failures, n, since}] when now - since < @lockout_seconds ->
        :ets.insert(@table, {:failures, n + 1, since})

      _ ->
        :ets.insert(@table, {:failures, 1, now})
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  # --- Completing -----------------------------------------------------------------

  @doc """
  Validates and applies the setup form: `%{"code", "password", "password_confirmation",
  "domain", "app_name", "admin_emails"}` (the platform administrators, who also become the
  default app's administrators, F-1116).
  Returns `:ok` or `{:error, %{field => message}}`.
  """
  def complete(params) do
    errors =
      %{}
      |> check(:code, code_error(params["code"]))
      |> check(:password, password_error(params["password"], params["password_confirmation"]))
      |> check(:domain, domain_error(params["domain"]))
      |> check(:app_name, if(present?(params["app_name"]), do: nil, else: "窓口名を入力してください"))
      |> check(:admin_emails, admin_emails_error(params["admin_emails"], params["domain"]))

    if errors == %{} do
      {:ok, _} = AdminAccess.force_set_password(params["password"])

      {:ok, setting} =
        Apps.platform(fn ->
          Settings.update_setting(Settings.get_setting!(), %{allowed_domain: params["domain"]})
        end)

      Apps.ensure_primary!()
      {:ok, _} = Apps.update(Apps.primary(), %{name: String.trim(params["app_name"])})

      # the platform administrators, also the default app's administrators (F-1116),
      # named before their first sign-in
      for email <- admin_emails(params["admin_emails"]) do
        {:ok, user} = AskDrive.Accounts.grant_admin(email)
        {:ok, _} = AskDrive.Accounts.add_app_admin(user, Apps.primary().slug)
      end

      {:ok, _} = complete!(setting)
      :ok
    else
      {:error, errors}
    end
  end

  defp complete!(setting) do
    result =
      setting
      |> Ecto.Changeset.change(
        setup_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> PlatformRepo.update()

    File.rm(code_path())
    mark_done()
    Logger.info("AskDrive: first-access setup complete")
    result
  end

  defp check(errors, _field, nil), do: errors
  defp check(errors, field, message), do: Map.put(errors, field, message)

  defp code_error(code) do
    case verify_code(code) do
      :ok -> nil
      {:error, :locked} -> "入力の失敗が続いたため、しばらく受け付けません（15 分後に再試行してください）"
      {:error, :invalid} -> "セットアップコードが正しくありません"
    end
  end

  defp password_error(password, confirmation) do
    min = AdminAccess.min_password_length()

    cond do
      not is_binary(password) or String.length(password) < min -> "#{min} 文字以上で入力してください"
      String.trim(password) != password -> "前後に空白を含めないでください"
      password != confirmation -> "確認用のパスワードが一致しません"
      true -> nil
    end
  end

  defp domain_error(domain) do
    cs =
      AskDrive.Settings.Setting.changeset(%AskDrive.Settings.Setting{}, %{allowed_domain: domain})

    cond do
      not present?(domain) -> "組織の Google Workspace ドメインを入力してください"
      cs.errors[:allowed_domain] -> "ドメイン名（例: company.com）で入力してください"
      true -> nil
    end
  end

  defp admin_emails(text),
    do:
      text
      |> to_string()
      |> String.split(~r/[\s,;、]+/, trim: true)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

  defp admin_emails_error(text, domain) do
    emails = admin_emails(text)

    domain =
      domain |> to_string() |> String.trim() |> String.downcase() |> String.trim_leading("@")

    cond do
      emails == [] ->
        "全体管理者のメールアドレスを入力してください"

      Enum.any?(emails, &(not String.match?(&1, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/))) ->
        "メールアドレスとして読み取れないものがあります"

      domain != "" and Enum.any?(emails, &(not String.ends_with?(&1, "@" <> domain))) ->
        "全体管理者は @#{domain} のアドレスにしてください"

      true ->
        nil
    end
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
