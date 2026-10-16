defmodule AskDrive.ACME.Renewal do
  @moduledoc """
  Gets and renews the served certificate from Let's Encrypt (spec F-1009 / F-1011).

  A run (`run/1`, one at a time) obtains a certificate with `AskDrive.ACME.issue/2`, checks it
  like an uploaded one (`AskDrive.SSL.validate/2`: key pair, validity, chain, host name, a
  TLS handshake) and installs it with `AskDrive.SSL.install/3` — the HTTPS listener restarts,
  and if it won't start with the new certificate the previous one is put back. What happened
  is kept on the platform setting row (`acme_checked_at`, `acme_last_ok`,
  `acme_last_result`) and sent to Google Chat when a webhook is set (F-1507). Each step is
  broadcast on `"acme"` for the admin screen.

  Renewal: the clock calls `maybe_nightly/1` every minute; in the night window, at most once a
  night, a run starts when the certificate needs one (`needs_certificate?/3`): it isn't a
  Let's Encrypt certificate for the configured host (or from the other environment), or a
  third of its lifetime or less is left — 30 days of a 90-day certificate, so a failed night
  is tried again for weeks before it expires, and shorter lifetimes are followed by
  themselves.
  """
  use GenServer
  require Logger

  alias AskDrive.{ACME, Clock, Settings, SSL}
  alias AskDrive.ACME.ValueDomain
  alias AskDrive.Notify.GoogleChat
  alias AskDrive.Runtime.Mode

  @topic "acme"
  @log_lines 100

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def topic, do: @topic

  @doc "The run in progress or the last one: `%{running?, by, started_at, log}`."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Starts a run now. `{:error, :running}` when one is already under way."
  def run(by), do: GenServer.call(__MODULE__, {:run, by})

  # --- When a certificate is needed ---------------------------------------------------------

  @doc """
  Whether the saved values are complete enough for a run (and HTTPS is on). A run by hand
  (「今すぐ取得」) needs only this, so a staging certificate can be tried before automatic
  renewal is switched on.
  """
  def ready?(setting) do
    setting != nil and SSL.enabled?() and present?(setting.acme_hostname) and
      present?(setting.acme_dns_zone) and present?(setting.valuedomain_api_key)
  end

  @doc "Whether automatic renewal is on and can run (F-206)."
  def configured?(setting), do: ready?(setting) and setting.acme_enabled == true

  @doc """
  Whether the served certificate (`SSL.current/0`'s metadata) should be replaced by a new
  Let's Encrypt one at `now`.
  """
  def needs_certificate?(setting, cert \\ SSL.current(), now \\ DateTime.utc_now()) do
    cond do
      not is_map(cert) -> true
      cert["source"] != "letsencrypt" -> true
      setting.acme_hostname not in (cert["names"] || []) -> true
      cert["acme_staging"] == true != (setting.acme_staging == true) -> true
      true -> renewal_due?(cert, now)
    end
  end

  defp renewal_due?(cert, now) do
    with {:ok, from, _} <- DateTime.from_iso8601(cert["not_before"] || ""),
         {:ok, to, _} <- DateTime.from_iso8601(cert["not_after"] || "") do
      DateTime.diff(to, now) < div(DateTime.diff(to, from), 3)
    else
      _ -> true
    end
  end

  @doc "When the served Let's Encrypt certificate will be renewed (nil if it isn't one)."
  def renew_after(cert \\ SSL.current()) do
    with %{"source" => "letsencrypt"} <- cert,
         {:ok, from, _} <- DateTime.from_iso8601(cert["not_before"] || ""),
         {:ok, to, _} <- DateTime.from_iso8601(cert["not_after"] || "") do
      DateTime.add(to, -div(DateTime.diff(to, from), 3))
    else
      _ -> nil
    end
  end

  @doc """
  Called by the clock every minute: in the night window, once a night, starts a run if the
  certificate needs one.
  """
  def maybe_nightly(now \\ Clock.local_now()) do
    setting = Settings.platform_setting()

    if configured?(setting) and Mode.calculate_current_mode(now) == :night_batch and
         (is_nil(setting.acme_checked_at) or
            DateTime.compare(setting.acme_checked_at, Mode.night_window_start_utc(now)) == :lt) and
         needs_certificate?(setting) do
      run("夜間の自動更新")
    end

    :ok
  rescue
    e -> Logger.error("ACME: nightly check crashed: #{Exception.message(e)}")
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  # --- GenServer ----------------------------------------------------------------------------

  @impl true
  def init(_opts),
    do: {:ok, %{running?: false, by: nil, started_at: nil, log: [], task: nil}}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call({:run, _by}, _from, %{running?: true} = state),
    do: {:reply, {:error, :running}, state}

  def handle_call({:run, by}, _from, state) do
    setting = Settings.platform_setting()

    if ready?(setting) do
      Settings.record_acme_result(%{acme_checked_at: DateTime.utc_now(:second)})
      server = self()
      log = fn line -> send(server, {:log, line}) end

      task =
        Task.Supervisor.async_nolink(AskDrive.TaskSupervisor, fn -> obtain(setting, log) end)

      state = %{
        state
        | running?: true,
          by: by,
          started_at: DateTime.utc_now(),
          log: [stamp("開始（#{by}）")],
          task: task.ref
      }

      Logger.info("ACME: obtaining a certificate for #{setting.acme_hostname} (#{by})")
      broadcast(state)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_configured}, state}
    end
  end

  @impl true
  def handle_info({:log, line}, state) do
    state = %{state | log: Enum.take([stamp(line) | state.log], @log_lines)}
    broadcast(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state),
    do: {:noreply, finish(state, {:error, "処理が異常終了しました: #{inspect(reason)}"})}

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish(state, result) do
    setting = Settings.platform_setting()

    {ok?, message} =
      case result do
        {:ok, info} ->
          {true,
           "#{info["names"] |> List.wrap() |> Enum.join(", ")} の証明書を取得して適用しました（有効期限 #{format_time(info["not_after"])}）"}

        {:error, message} ->
          {false, message}
      end

    Settings.record_acme_result(%{acme_last_ok: ok?, acme_last_result: message})

    if ok?,
      do: Logger.info("ACME: #{message}"),
      else: Logger.error("ACME: failed: #{message}")

    GoogleChat.send_async(notice(ok?, message, setting))

    state = %{
      state
      | running?: false,
        task: nil,
        log: [stamp(if(ok?, do: "完了: ", else: "失敗: ") <> message) | state.log]
    }

    broadcast(state)
    state
  end

  # --- A run (in its own process) -----------------------------------------------------------

  defp obtain(setting, log) do
    host = setting.acme_hostname
    env = if setting.acme_staging, do: "staging", else: "production"
    acme_dir = Path.join(SSL.ssl_dir(), "acme")

    dns_config = %{
      api_key: setting.valuedomain_api_key,
      zone: setting.acme_dns_zone,
      backup_dir: Path.join(acme_dir, "dns_backup")
    }

    opts =
      [
        directory: ACME.directory_url(setting.acme_staging),
        account_dir: Path.join(acme_dir, env),
        dns: {dns_module(), dns_config},
        zone: setting.acme_dns_zone,
        email: setting.acme_email,
        log: log
      ] ++ Application.get_env(:ask_drive, :acme_issue_options, [])

    with {:ok, pem} <- ACME.issue(host, opts),
         _ = log.("証明書を検証しています"),
         {:ok, info} <- validate(pem, host),
         _ = log.("証明書を適用しています（HTTPS を再起動します）"),
         :ok <-
           SSL.install(pem, Map.put(info, "acme_staging", setting.acme_staging), "letsencrypt") do
      {:ok, info}
    end
  end

  defp validate(pem, host) do
    case SSL.validate(pem, host) do
      {:ok, info} -> {:ok, info}
      {:error, errors} -> {:error, "取得した証明書の検証に失敗しました: " <> Enum.join(errors, " / ")}
    end
  end

  defp dns_module, do: Application.get_env(:ask_drive, :acme_dns_module, ValueDomain)

  # --- Helpers ------------------------------------------------------------------------------

  defp notice(true, message, setting) do
    staging = if setting && setting.acme_staging, do: "（テスト用の staging 証明書）", else: ""
    "🔐 AskDrive（#{GoogleChat.host()}）: Let's Encrypt #{staging}#{message}"
  end

  defp notice(false, message, _setting) do
    "⚠️ AskDrive（#{GoogleChat.host()}）: Let's Encrypt の証明書を取得できませんでした。" <>
      "現在の証明書のまま動いています。#{message}"
  end

  defp public(state), do: Map.take(state, [:running?, :by, :started_at, :log])

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(AskDrive.PubSub, @topic, {:acme_status, public(state)})

  defp stamp(line) do
    time = Clock.local_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_time()
    "#{Time.to_iso8601(time)} #{line}"
  end

  defp format_time(iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, dt, _} ->
        Clock.format(dt, "%Y-%m-%d %H:%M")

      _ ->
        iso
    end
  end
end
