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
    GenServer.call(__MODULE__, :check, 30_000)
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
    results = perform_checks()
    log_results(results)
    {:noreply, %{state | status: :ready, results: results}}
  end

  @impl true
  def handle_call(:check, _from, state) do
    results = perform_checks()
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
  end

  defp log_provider(role, provider, result) do
    label = "#{role} (#{LLM.label(provider)})"

    case result do
      {:ok, info} -> Logger.info("  [✓] #{label}: #{info}")
      {:error, err} -> Logger.warning("  [✗] #{label}: #{err}")
    end
  end
end
