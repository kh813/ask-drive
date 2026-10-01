defmodule AskDrive.LLM.OllamaServer do
  @moduledoc """
  Whether AskDrive needs its local Ollama, and starting it when it does (spec F-829).

  `./app.sh start` used to start Ollama on every boot, even when every desk runs on a cloud
  API. Now the app records whether any desk uses Ollama (embedding, batch generation or chat
  summary) in `ollama_needed` next to the platform database, and `app.sh` reads it: "yes"
  starts Ollama, "no" doesn't; without the file (first start) it goes by the providers in
  `.env.prod`. When a setting switches to Ollama while it isn't running, the app starts
  `ollama serve` itself, so no restart is needed.
  """
  require Logger

  alias AskDrive.LLM.Providers.Ollama
  alias AskDrive.{LLM, Settings}

  @doc "The file `app.sh` reads: \"yes\" or \"no\"."
  def flag_path do
    dir =
      Application.get_env(:ask_drive, :setup_dir) ||
        Path.dirname(AskDrive.Repo.config()[:database] || Path.expand("ask_drive.db"))

    Path.join(dir, "ollama_needed")
  end

  @doc "Records whether Ollama is needed (the file `app.sh start` reads)."
  def record_needed(needed?) when is_boolean(needed?) do
    if managed?(), do: File.write(flag_path(), if(needed?, do: "yes\n", else: "no\n")), else: :ok
  end

  @doc """
  Makes sure Ollama answers, starting `ollama serve` in the background when it doesn't and
  the binary is on the PATH (`.runtime/bin`). `:ok`, `:started` or `{:error, reason}`.
  """
  def ensure_running(setting \\ Settings.platform_setting!()) do
    opts = LLM.provider_opts("ollama", setting)

    cond do
      match?({:ok, _}, Ollama.list_models(opts)) -> :ok
      not managed?() -> {:error, :disabled}
      true -> start(opts)
    end
  end

  # off in tests, which neither start processes nor write next to the database
  defp managed?, do: Application.get_env(:ask_drive, :manage_ollama, true)

  defp start(opts) do
    case System.find_executable("ollama") do
      nil ->
        {:error, :not_installed}

      exe ->
        log = if File.dir?("log"), do: Path.expand("log/ollama.log"), else: "/dev/null"
        # the same tuning `app.sh start` applies (one model at a time, flash attention)
        env = [
          {"OLLAMA_MAX_LOADED_MODELS", System.get_env("OLLAMA_MAX_LOADED_MODELS", "1")},
          {"OLLAMA_NUM_PARALLEL", System.get_env("OLLAMA_NUM_PARALLEL", "1")},
          {"OLLAMA_FLASH_ATTENTION", System.get_env("OLLAMA_FLASH_ATTENTION", "1")},
          {"OLLAMA_KV_CACHE_TYPE", System.get_env("OLLAMA_KV_CACHE_TYPE", "q8_0")}
        ]

        Logger.info("OllamaServer: Ollama isn't running; starting #{exe} serve")

        {_, 0} =
          System.cmd("/bin/sh", ["-c", ~s(nohup "$0" serve >> "$1" 2>&1 &), exe, log], env: env)

        wait_until_up(opts, 30)
    end
  end

  defp wait_until_up(_opts, 0), do: {:error, :timeout}

  defp wait_until_up(opts, tries) do
    case Ollama.list_models(opts) do
      {:ok, _} ->
        :started

      _ ->
        Process.sleep(1_000)
        wait_until_up(opts, tries - 1)
    end
  end
end
