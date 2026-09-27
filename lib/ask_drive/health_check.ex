defmodule AskDrive.HealthCheck do
  @moduledoc """
  GenServer that performs system startup health checks:
  - SQLite sqlite-vec extension
  - Ollama availability and version
  - External CLI tools (pdftotext, pandoc)
  """
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs health checks and returns a summary map.
  """
  def check do
    GenServer.call(__MODULE__, :check)
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
    %{
      sqlite_vec: check_sqlite_vec(),
      ollama: check_ollama(),
      pdftotext: check_cli("pdftotext", ["-v"]),
      pandoc: check_cli("pandoc", ["-v"])
    }
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

  defp check_ollama do
    ollama_host = System.get_env("OLLAMA_HOST", "http://localhost:11434")

    case Req.get("#{ollama_host}/api/version", receive_timeout: 3000) do
      {:ok, %{status: 200, body: %{"version" => version}}} ->
        {:ok, version}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
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

    case results.ollama do
      {:ok, ver} -> Logger.info("  [✓] Ollama: v#{ver}")
      {:error, err} -> Logger.warning("  [✗] Ollama: #{err}")
    end

    case results.pdftotext do
      {:ok, ver} -> Logger.info("  [✓] pdftotext: #{ver}")
      {:error, err} -> Logger.warning("  [✗] pdftotext: #{err}")
    end

    case results.pandoc do
      {:ok, ver} -> Logger.info("  [✓] pandoc: #{ver}")
      {:error, err} -> Logger.warning("  [✗] pandoc: #{err}")
    end
  end
end
