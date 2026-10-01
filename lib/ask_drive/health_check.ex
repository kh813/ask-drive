defmodule AskDrive.HealthCheck do
  @moduledoc """
  GenServer that performs system startup health checks:
  - SQLite sqlite-vec extension
  - Reachability of the configured generation and embedding providers
  - External CLI tools (pdftotext, pandoc)
  """
  use GenServer
  require Logger

  alias AskDrive.LLM
  alias AskDrive.LLM.HTTP

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs health checks and returns a summary map.
  """
  def check do
    # Two provider probes with their own socket timeouts can outlast the default 5s call
    # timeout; a slow health check must not crash the LiveView that asked for it.
    # The checks run in this server's process, so tell it which app's providers to probe
    GenServer.call(__MODULE__, {:check, AskDrive.Apps.current()}, 30_000)
  catch
    :exit, _reason -> unavailable_results()
  end

  defp unavailable_results do
    %{
      sqlite_vec: {:error, "ヘルスチェックがタイムアウトしました"},
      llm_generation: {:error, "ヘルスチェックがタイムアウトしました"},
      llm_embedding: {:error, "ヘルスチェックがタイムアウトしました"},
      generation_provider: "ollama",
      embedding_provider: "ollama",
      pdftotext: {:error, "unknown"},
      pandoc: {:error, "unknown"}
    }
  end

  @impl true
  def init(_opts) do
    # Run initial check asynchronously after boot
    send(self(), :run_startup_check)
    {:ok, %{status: :initializing, results: %{}}}
  end

  @impl true
  def handle_info(:run_startup_check, state) do
    abort_interrupted_batches()
    # first-access setup: print the setup code if it's still needed (spec 6.12)
    AskDrive.Setup.prepare()
    results = perform_checks()
    log_results(results)
    {:noreply, %{state | status: :ready, results: results}}
  end

  @impl true
  def handle_call({:check, app}, _from, state) do
    results = if app, do: AskDrive.Apps.with_app(app, &perform_checks/0), else: perform_checks()
    {:reply, results, %{state | results: results}}
  end

  defp perform_checks do
    setting = load_setting()

    %{
      sqlite_vec: check_sqlite_vec(),
      llm_generation: check_provider(:generation, setting),
      llm_embedding: check_provider(:embedding, setting),
      generation_provider: LLM.generation_provider(setting),
      embedding_provider: LLM.embedding_provider(setting),
      pdftotext: check_cli("pdftotext", ["-v"]),
      pandoc: check_cli("pandoc", ["-v"])
    }
  end

  defp load_setting do
    AskDrive.Settings.get_setting()
  rescue
    _ -> nil
  end

  defp check_sqlite_vec do
    case AskDrive.Repo.query("SELECT vec_version();") do
      {:ok, %{rows: [[version]]}} ->
        {:ok, version}

      error ->
        {:error, inspect(error)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp check_provider(role, setting) do
    case LLM.health(role, setting) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, HTTP.describe(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp check_cli(cmd, args) do
    case System.find_executable(cmd) do
      nil ->
        {:error, "#{cmd} not found in PATH"}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} ->
            first_line = output |> String.split("\n", trim: true) |> List.first() || "available"
            {:ok, first_line}

          {output, _code} ->
            # Some tools return non-zero on -v (like poppler pdftotext exiting with 99 on pdftotext -v)
            first_line = output |> String.split("\n", trim: true) |> List.first() || "available"
            {:ok, first_line}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp log_results(results) do
    Logger.info("=== AskDrive 起動時ヘルスチェック ===")

    case results.sqlite_vec do
      {:ok, ver} -> Logger.info("  [✓] sqlite-vec: #{ver}")
      {:error, err} -> Logger.warning("  [✗] sqlite-vec: #{err}")
    end

    log_provider("回答生成", results.generation_provider, results.llm_generation)
    log_provider("埋め込み", results.embedding_provider, results.llm_embedding)

    case results.pdftotext do
      {:ok, ver} -> Logger.info("  [✓] pdftotext: #{ver}")
      {:error, err} -> Logger.warning("  [✗] pdftotext: #{err}")
    end

    case results.pandoc do
      {:ok, ver} -> Logger.info("  [✓] pandoc: #{ver}")
      {:error, err} -> Logger.warning("  [✗] pandoc: #{err}")
    end

    # Say which auth mode is live, so "is the flag in .env.prod actually reaching the
    # process?" can be answered from the log instead of by trial and error in a browser.
    if AskDriveWeb.UserAuth.auth_disabled?() do
      Logger.warning("  [!] 認証: 無効 (ASK_DRIVE_DISABLE_AUTH) — /admin を含め誰でも管理者として操作できます")
    else
      Logger.info("  [✓] 認証: 有効 (管理画面はログイン + 本人確認が必要)")
    end
  end

  defp log_provider(role, provider, result) do
    label = "#{role} (#{LLM.label(provider)})"

    case result do
      {:ok, info} -> Logger.info("  [✓] #{label}: #{info}")
      {:error, err} -> Logger.warning("  [✗] #{label}: #{err}")
    end
  end

  # A batch runs inside the app process, so one still "running" at boot was cut off by a
  # restart (or crash) and will never finish. Say so instead of showing it as running forever.
  defp abort_interrupted_batches do
    import Ecto.Query

    # every app's database: a restart interrupts whichever app's batch was running
    count =
      AskDrive.Apps.each(fn _app ->
        {n, _} =
          AskDrive.Repo.update_all(
            from(b in AskDrive.Batch.BatchRun, where: b.status == "running"),
            set: [
              status: "aborted",
              finished_at: DateTime.utc_now() |> DateTime.truncate(:second),
              error: "アプリの再起動によりバッチが中断されました"
            ]
          )

        n
      end)
      |> Enum.map(fn {_app, n} -> n end)
      |> Enum.sum()

    if count > 0, do: Logger.warning("  [!] 中断されたバッチ #{count} 件を aborted に更新しました")
  rescue
    e -> Logger.warning("Could not mark interrupted batches as aborted: #{Exception.message(e)}")
  end
end
