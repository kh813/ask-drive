defmodule AskDrive.Updates.Server do
  @moduledoc """
  Runs an update (spec 12.8, F-1502–F-1505) through its phases:

    * `:building` — `./app.sh update --yes --build-only` runs as a port, at low priority, while
      the server and the batch carry on; its output is kept and broadcast on `"updates"`.
      A failed build changes nothing in the running server (`:failed`).
    * `:waiting_batch` — built. Without a service manager to restart the server, it stops
      here (`:built`: restart by hand). Otherwise the batch is paused at its next item boundary
      (`wait: :boundary`) or left to finish (`wait: :batch_end`), and no batch starts.
    * `:restarting` — no batch runs: what to continue is written down, every open page is told
      to show "updating" (`"system"` topic, F-1505), and the server exits with status 75 for
      launchd / systemd to start it again, on the new release.

  After that restart, `init/1` finds what was written down: it records the result and, after a
  short delay, continues the paused batches — the nightly batch with its desks and cut-off, a
  manual batch as a re-run from where it stopped (F-1503).
  """
  use GenServer
  require Logger

  alias AskDrive.{Apps, Updates}
  alias AskDrive.Notify.GoogleChat
  alias AskDrive.Batch.{BatchRun, Night, Scheduler}

  @topic "updates"
  @log_lines 400
  # status the service manager restarts on (launchd KeepAlive: non-zero; systemd on-failure)
  @restart_status 75

  # the BEAM's own environment, which must not leak into the build's mix / erl
  @unset_env ~w(BINDIR ROOTDIR EMU PROGNAME ERL_LIBS RELEASE_ROOT RELEASE_NAME RELEASE_VSN
    RELEASE_COMMAND RELEASE_PROG RELEASE_TMP RELEASE_NODE RELEASE_COOKIE RELEASE_MODE
    RELEASE_SYS_CONFIG RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_BOOT_SCRIPT
    RELEASE_BOOT_SCRIPT_CLEAN RELEASE_DISTRIBUTION)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def topic, do: @topic

  def start_update(opts), do: GenServer.call(__MODULE__, {:start, opts})
  def status, do: GenServer.call(__MODULE__, :status)
  def restart_now, do: GenServer.call(__MODULE__, :restart_now)
  def cancel, do: GenServer.call(__MODULE__, :cancel)

  @doc "Where the restart writes down what to continue."
  def marker_path do
    dir = Application.get_env(:ask_drive, :update_state_dir) || Path.join(root(), "log")
    Path.join(dir, "update_pending.json")
  end

  defp root, do: Application.get_env(:ask_drive, :update_root) || File.cwd!()

  # --- GenServer ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Updates.put_phase(:idle)
    send(self(), :after_boot)
    {:ok, idle()}
  end

  defp idle do
    %{
      phase: :idle,
      from: Updates.current_version(),
      to: nil,
      by: nil,
      wait: :boundary,
      started_at: nil,
      message: nil,
      log: [],
      port: nil,
      resume: nil
    }
  end

  @impl true
  def handle_call({:start, _opts}, _from, %{phase: phase} = state)
      when phase in [:building, :waiting_batch, :restarting] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:start, opts}, _from, _state) do
    state = %{
      idle()
      | phase: :building,
        to: opts[:to],
        by: opts[:by] || "管理者",
        wait: if(opts[:wait] == :batch_end, do: :batch_end, else: :boundary),
        started_at: DateTime.utc_now() |> DateTime.truncate(:second),
        message: "新しいバージョンをビルドしています（サーバーとバッチはこのまま動きます）"
    }

    Logger.info("Updates: started by #{state.by} (v#{state.from} → v#{state.to || "?"})")
    state = %{state | port: open_build()}
    # whoever looks after the server learns of it, even at night (F-1507)
    GoogleChat.send_async(start_notice(state))

    state =
      log(
        state,
        "=== #{AskDrive.Clock.format(state.started_at, "%Y-%m-%d %H:%M")} アップデート開始（#{state.by}）==="
      )

    {:reply, :ok, enter(state, :building)}
  end

  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call(:restart_now, _from, %{phase: :waiting_batch} = state) do
    Logger.warning("Updates: restarting now, without waiting for the batch (#{state.by})")
    {:reply, :ok, restart(state)}
  end

  def handle_call(:restart_now, _from, state), do: {:reply, {:error, :not_waiting}, state}

  def handle_call(:cancel, _from, %{phase: :building, port: port} = state) do
    kill_build(port)
    state = log(%{state | port: nil}, "=== 中止しました ===")
    {:reply, :ok, enter(%{state | message: "ビルドを中止しました。稼働中のサーバーは変わっていません。"}, :failed)}
  end

  def handle_call(:cancel, _from, state), do: {:reply, {:error, :not_building}, state}

  @impl true
  def handle_info({port, {:data, {_eol, line}}}, %{port: port} = state) do
    {:noreply, log(state, line)}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    state = log(%{state | port: nil}, "=== ビルド完了 ===")
    {:noreply, built(state)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("Updates: build failed with status #{code}")
    GoogleChat.send_async(build_failed_notice(state, code))
    state = log(%{state | port: nil}, "=== ビルドに失敗しました（終了コード #{code}）===")

    {:noreply,
     enter(
       %{state | message: "ビルドに失敗しました（終了コード #{code}）。稼働中のサーバーはそのままです。ログを確認してください。"},
       :failed
     )}
  end

  # waiting for the batch to pause (or finish)
  def handle_info(:poll, %{phase: :waiting_batch} = state) do
    if Scheduler.running_anywhere?() do
      Process.send_after(self(), :poll, poll_interval())
      {:noreply, state}
    else
      {:noreply, restart(state)}
    end
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info(:halt, state) do
    restart_fun().()
    {:noreply, state}
  end

  # after a restart: what the update before it wrote down
  def handle_info(:after_boot, state) do
    case read_marker() do
      nil ->
        {:noreply, state}

      marker ->
        File.rm(marker_path())
        result = boot_result(marker, Updates.current_version())
        Logger.info("Updates: #{result}")
        Updates.save_platform(%{update_last_result: result})
        Process.send_after(self(), {:resume, marker}, resume_delay())
        # once the server is fully up and answering (F-1507)
        Process.send_after(self(), {:notify_boot, marker}, notify_delay())
        {:noreply, %{state | message: result}}
    end
  end

  def handle_info({:notify_boot, marker}, state) do
    GoogleChat.send_async(boot_notice(marker, Updates.current_version(), healthy?()))
    {:noreply, state}
  end

  def handle_info({:resume, marker}, state) do
    Task.start(fn -> resume(marker) end)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Phases ------------------------------------------------------------------------------

  defp enter(state, phase) do
    # waiting for the batch to finish holds nothing back (the night may go on to the next
    # desk); pausing it at a boundary means no batch starts now
    Updates.put_phase(
      if phase == :waiting_batch and state.wait == :batch_end, do: :waiting_batch_end, else: phase
    )

    state = %{state | phase: phase}
    Phoenix.PubSub.broadcast(AskDrive.PubSub, @topic, {:update_status, public(state)})
    state
  end

  defp built(state) do
    if service_managed?() do
      # what the batch is doing now, to continue after the restart (Night is gone by then)
      resume = %{night: Night.current(), manual: running_manual_runs()}
      # from here no batch starts (when pausing at a boundary)
      state = enter(state, :waiting_batch)

      message =
        cond do
          not Scheduler.running_anywhere?() ->
            "ビルドが完了しました。再起動します"

          state.wait == :boundary ->
            Apps.each(fn _app -> Scheduler.pause_for_update() end)
            "ビルドが完了しました。バッチが区切りで一時停止するのを待っています（再起動後に続きから再開します）"

          true ->
            "ビルドが完了しました。実行中のバッチが終わるのを待っています（終わり次第、再起動します）"
        end

      send(self(), :poll)
      enter(%{state | resume: resume, message: message}, :waiting_batch)
    else
      enter(
        %{
          state
          | message:
              "ビルドが完了しました。AskDrive が常駐サービスとして登録されていないため、自動では再起動できません。サーバーで ./app.sh restart を実行すると新しいバージョンで起動します（./app.sh service install で登録すると、次回から画面だけで完了します）。"
        },
        :built
      )
    end
  end

  defp restart(state) do
    write_marker(%{
      "from" => state.from,
      "to" => state.to,
      "by" => state.by,
      "started_at" => state.started_at && DateTime.to_iso8601(state.started_at),
      "resume" => encode_resume(state.resume)
    })

    # every open page shows "updating" until it can reconnect (F-1505)
    Phoenix.PubSub.broadcast(
      AskDrive.PubSub,
      "system",
      {:system_updating, %{from: state.from, to: state.to}}
    )

    Logger.warning("Updates: restarting into the new release (status #{@restart_status})")
    Process.send_after(self(), :halt, halt_delay())
    enter(%{state | message: "再起動しています…"}, :restarting)
  end

  # --- Notices (F-1507) ---------------------------------------------------------------------

  @doc false
  def start_notice(state) do
    """
    🔄 *AskDrive のアップデートを開始します*
    v#{state.from} → #{if state.to, do: "v#{state.to}", else: "最新版"}（#{state.by}）
    サーバー: #{GoogleChat.host()}
    ビルドが終わると 30 秒ほど再起動します。完了の通知が届かない場合は、サーバーのログ（log/update.log、log/ask_drive_stderr.log）を確認してください。
    """
    |> String.trim()
  end

  @doc false
  def build_failed_notice(state, code) do
    """
    ⚠️ *AskDrive のアップデートに失敗しました*
    ビルドに失敗したため（終了コード #{code}）、v#{state.from} のまま稼働しています（#{state.by}）。
    サーバー: #{GoogleChat.host()}
    ログ: log/update.log
    """
    |> String.trim()
  end

  @doc false
  def boot_notice(marker, running, healthy?) do
    from = marker["from"]
    by = marker["by"] || "管理者"
    switched? = running != from

    cond do
      switched? and healthy? ->
        """
        ✅ *AskDrive のアップデートが完了しました*
        v#{from} → v#{running} で起動し、正常に稼働しています（#{by}）。
        サーバー: #{GoogleChat.host()}
        """

      switched? ->
        """
        ⚠️ *AskDrive は v#{running} で起動しましたが、正常に稼働していない可能性があります*
        Web 画面またはデータベースが応答していません（#{by}）。
        サーバー: #{GoogleChat.host()}
        ログ: log/ask_drive_stderr.log
        """

      true ->
        """
        ⚠️ *AskDrive はアップデート後も v#{running} のままで起動しました*
        新しいバージョンに切り替わっていません（#{by}）。
        サーバー: #{GoogleChat.host()}
        ログ: log/update.log、log/ask_drive_stderr.log
        """
    end
    |> String.trim()
  end

  # up and answering: the web endpoint runs and the database answers
  defp healthy? do
    Process.whereis(AskDriveWeb.Endpoint) != nil and
      match?({:ok, _}, Ecto.Adapters.SQL.query(AskDrive.Repo, "SELECT 1", []))
  rescue
    _ -> false
  end

  # --- After the restart ---------------------------------------------------------------------

  @doc false
  def boot_result(marker, running) do
    from = marker["from"]
    to = marker["to"]
    by = marker["by"] || "管理者"

    cond do
      to && running == to -> "v#{from} から v#{to} にアップデートしました（#{by}）"
      running != from -> "v#{from} から v#{running} にアップデートしました（#{by}）"
      true -> "アップデート後も v#{running} のままで起動しました（#{by}）。ログ（log/update.log）を確認してください"
    end
  end

  @doc false
  def resume(%{"resume" => resume}) when is_map(resume) do
    if night = resume["night"] do
      apps = night_apps_left(night)

      if apps != [] do
        {:ok, cutoff, _} = DateTime.from_iso8601(night["cutoff"])

        Logger.info(
          "Updates: continuing the nightly batch (#{Enum.map_join(apps, ", ", & &1.slug)})"
        )

        Night.run(apps, cutoff: cutoff)
      end
    end

    apps = Apps.list()

    for %{"slug" => slug, "kind" => kind} <- resume["manual"] || [] do
      case Enum.find(apps, &(&1.slug == slug)) do
        nil ->
          :ok

        app ->
          Logger.info("Updates: continuing the #{kind} batch of #{slug}")

          Apps.with_app(app, fn ->
            Scheduler.run_batch(ingest_only: kind == "ingest_only", trigger: "manual")
          end)
      end
    end

    :ok
  end

  def resume(_marker), do: :ok

  # the night's desks that hadn't finished: no run since the night started that ended
  defp night_apps_left(night) do
    {:ok, started_at, _} = DateTime.from_iso8601(night["started_at"])
    slugs = night["slugs"] || []

    Apps.list()
    |> Enum.filter(&(&1.slug in slugs))
    |> Enum.reject(fn app ->
      Apps.with_app(app, fn ->
        import Ecto.Query

        AskDrive.Repo.exists?(
          from b in BatchRun,
            where:
              b.started_at >= ^started_at and
                b.status in ["completed", "deadline_reached", "failed", "stopped", "skipped"]
        )
      end)
    end)
  end

  defp running_manual_runs do
    Apps.each(fn app ->
      import Ecto.Query

      AskDrive.Repo.all(
        from b in BatchRun,
          where: b.status == "running" and b.trigger == "manual",
          select: b.kind
      )
      |> Enum.map(&%{slug: app.slug, kind: &1})
    end)
    |> Enum.flat_map(fn {_app, runs} -> runs end)
  end

  defp encode_resume(nil), do: nil

  defp encode_resume(%{night: night, manual: manual}) do
    %{
      "night" =>
        night &&
          %{
            "slugs" => night.slugs,
            "cutoff" => DateTime.to_iso8601(night.cutoff),
            "started_at" => DateTime.to_iso8601(night.started_at)
          },
      "manual" => Enum.map(manual, &%{"slug" => &1.slug, "kind" => &1.kind})
    }
  end

  defp write_marker(data) do
    File.mkdir_p!(Path.dirname(marker_path()))
    File.write!(marker_path(), Jason.encode!(data))
  end

  defp read_marker do
    with {:ok, json} <- File.read(marker_path()),
         {:ok, data} <- Jason.decode(json) do
      data
    else
      _ -> nil
    end
  end

  # --- The build -----------------------------------------------------------------------------

  defp open_build do
    {exe, args} =
      case Application.get_env(:ask_drive, :update_build_command) do
        {exe, args} ->
          {exe, args}

        nil ->
          app_sh = Path.join(root(), "app.sh")
          bash = System.find_executable("bash")
          # low priority: the batch and the chat keep the CPU
          case System.find_executable("nice") do
            nil -> {bash, [app_sh, "update", "--yes", "--build-only"]}
            nice -> {nice, ["-n", "10", bash, app_sh, "update", "--yes", "--build-only"]}
          end
      end

    Port.open({:spawn_executable, exe}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 4096},
      args: args,
      cd: root(),
      env: Enum.map(@unset_env, &{String.to_charlist(&1), false})
    ])
  end

  defp kill_build(nil), do: :ok

  defp kill_build(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("pkill", ["-TERM", "-P", to_string(pid)], stderr_to_stdout: true)
        System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    Port.close(port)
  rescue
    _ -> :ok
  end

  defp log(state, line) do
    line = String.replace(line, ~r/\e\[[0-9;]*m/, "")
    append_log_file(line)
    Phoenix.PubSub.broadcast(AskDrive.PubSub, @topic, {:update_log, line})
    %{state | log: Enum.take([line | state.log], @log_lines)}
  end

  defp append_log_file(line) do
    path = Path.join(Path.dirname(marker_path()), "update.log")
    File.mkdir_p(Path.dirname(path))
    File.write(path, line <> "\n", [:append])
  end

  defp public(state) do
    state
    |> Map.take([:phase, :from, :to, :by, :wait, :started_at, :message])
    |> Map.put(:log, Enum.reverse(state.log))
  end

  # --- Seams for tests ---------------------------------------------------------------------

  defp service_managed? do
    case Application.get_env(:ask_drive, :update_service_check) do
      fun when is_function(fun, 0) ->
        fun.()

      nil ->
        app_sh = Path.join(root(), "app.sh")

        File.exists?(app_sh) and
          match?(
            {_, 0},
            System.cmd("bash", [app_sh, "service", "registered"], stderr_to_stdout: true)
          )
    end
  end

  defp restart_fun,
    do:
      Application.get_env(:ask_drive, :update_restart_fun) ||
        fn -> System.stop(@restart_status) end

  defp poll_interval, do: Application.get_env(:ask_drive, :update_poll_ms, 2_000)
  defp halt_delay, do: Application.get_env(:ask_drive, :update_halt_ms, 1_500)
  defp resume_delay, do: Application.get_env(:ask_drive, :update_resume_ms, 15_000)
  defp notify_delay, do: Application.get_env(:ask_drive, :update_notify_ms, 10_000)
end
