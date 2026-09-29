defmodule AskDrive.LLM.OllamaModels do
  @moduledoc """
  Keeps the Ollama models AskDrive needs available, pulling them through Ollama's HTTP API
  (spec F-827).

  Ollama runs privately for the app (`.runtime/bin`, not on anyone's PATH), so an admin can't
  simply type `ollama pull` any more. Instead:

    * at boot — i.e. after every update — models referenced by the settings (embedding,
      local batch generation, chat summary) that aren't installed are pulled in the
      background;
    * the admin screen lists installed and required models and can pull any model by name,
      with progress;
    * saving settings that name a missing model starts its pull.

  Pull progress lives in this GenServer and is broadcast on PubSub topic "ollama_models".
  """
  use GenServer
  require Logger

  alias AskDrive.{LLM, Settings}
  alias AskDrive.LLM.Providers.Ollama

  @topic "ollama_models"
  @boot_delay_ms 5_000

  # --- API ----------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def topic, do: @topic

  @doc "Pulls in progress or finished: `%{model => %{status:, completed:, total:, error:}}`."
  def pulls, do: GenServer.call(__MODULE__, :pulls)

  @doc false
  # Forgets finished pulls (tests: the state outlives each test)
  def reset_pulls, do: GenServer.call(__MODULE__, :reset_pulls)

  @doc "Starts pulling `model` in the background (no-op if it's already being pulled)."
  def pull_async(model) when is_binary(model) do
    model = String.trim(model)
    if model != "", do: GenServer.cast(__MODULE__, {:pull, model})
    :ok
  end

  @doc "Models every app needs, `[{app, role, model}]` (spec 6.11: one Ollama for all apps)."
  def required_all do
    AskDrive.Apps.each(fn app ->
      Enum.map(required(Settings.get_setting!()), fn {role, model} -> {app, role, model} end)
    end)
    |> Enum.flat_map(fn {_app, rows} -> rows end)
  end

  @doc """
  Starts pulls for every required model that isn't installed — of the given settings' app,
  or of all apps when called with `:all` (boot). Returns what it started.
  """
  def ensure_required(setting \\ Settings.get_setting!())

  def ensure_required(:all) do
    with {:ok, names} <- installed(Settings.platform_setting!()) do
      missing =
        required_all()
        |> Enum.map(fn {_app, _role, model} -> model end)
        |> Enum.uniq()
        |> Enum.reject(&installed?(&1, names))

      Enum.each(missing, &pull_async/1)
      {:ok, missing}
    end
  end

  def ensure_required(setting) do
    case installed(setting) do
      {:ok, names} ->
        missing =
          setting
          |> required()
          |> Enum.map(fn {_role, model} -> model end)
          |> Enum.uniq()
          |> Enum.reject(&installed?(&1, names))

        Enum.each(missing, &pull_async/1)
        {:ok, missing}

      error ->
        error
    end
  end

  @doc "Installed model names, as Ollama reports them (e.g. \"bge-m3:latest\")."
  def installed(setting \\ Settings.get_setting!()) do
    Ollama.list_models(LLM.provider_opts("ollama", setting))
  end

  @doc "Whether `model` is among `names` (a missing tag means \":latest\", as in Ollama)."
  def installed?(model, names) when is_list(names) do
    normalize(model) in Enum.map(names, &normalize/1)
  end

  @doc """
  Models the current settings would run on Ollama, as `[{role_label, model}]`: embedding,
  local batch generation, and the chat summary when their provider is Ollama.
  """
  def required(setting) do
    chat = AskDrive.ChatSummary.provider_and_model(setting)

    [
      {"埋め込み", LLM.embedding_provider(setting), LLM.embedding_model(setting)},
      {"夜間バッチ（QA 生成）", LLM.generation_provider(setting), LLM.generation_model(setting)},
      {"チャット要約", elem(chat, 0), elem(chat, 1)}
    ]
    |> Enum.filter(fn {_role, provider, model} ->
      provider == "ollama" and is_binary(model) and model != ""
    end)
    |> Enum.map(fn {role, _provider, model} -> {role, model} end)
  end

  defp normalize(name) do
    name = String.trim(name)
    if String.contains?(name, ":"), do: name, else: name <> ":latest"
  end

  # --- GenServer ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    if Application.get_env(:ask_drive, :auto_pull_models, true),
      do: Process.send_after(self(), :ensure_required, @boot_delay_ms)

    {:ok, %{pulls: %{}}}
  end

  @impl true
  def handle_call(:pulls, _from, state), do: {:reply, state.pulls, state}

  def handle_call(:reset_pulls, _from, state), do: {:reply, :ok, %{state | pulls: %{}}}

  @impl true
  def handle_cast({:pull, model}, state) do
    if get_in(state.pulls, [model, :status]) in ["pulling", "starting"] do
      {:noreply, state}
    else
      server = self()
      setting = Settings.get_setting!()

      Task.start(fn ->
        result =
          Ollama.pull(model, LLM.provider_opts("ollama", setting), fn progress ->
            send(server, {:progress, model, progress})
          end)

        send(server, {:done, model, result})
      end)

      Logger.info("OllamaModels: pulling #{model}")

      {:noreply,
       put_pull(state, model, %{status: "starting", completed: 0, total: 0, error: nil})}
    end
  end

  @impl true
  def handle_info(:ensure_required, state) do
    case ensure_required(:all) do
      {:ok, []} ->
        Logger.info("OllamaModels: all required models are installed")

      {:ok, missing} ->
        Logger.info("OllamaModels: pulling missing models #{inspect(missing)}")

      {:error, reason} ->
        Logger.warning("OllamaModels: could not list models: #{inspect(reason)}")
    end

    {:noreply, state}
  rescue
    e ->
      Logger.warning("OllamaModels: ensure_required failed: #{Exception.message(e)}")
      {:noreply, state}
  end

  def handle_info({:progress, model, progress}, state) do
    entry =
      state.pulls
      |> Map.get(model, %{})
      |> Map.merge(%{status: "pulling", error: nil})
      |> Map.merge(Map.take(progress, [:completed, :total, :detail]))

    {:noreply, put_pull(state, model, entry)}
  end

  def handle_info({:done, model, :ok}, state) do
    Logger.info("OllamaModels: #{model} is ready")
    {:noreply, put_pull(state, model, %{status: "done", completed: 0, total: 0, error: nil})}
  end

  def handle_info({:done, model, {:error, reason}}, state) do
    Logger.error("OllamaModels: pulling #{model} failed: #{inspect(reason)}")

    {:noreply,
     put_pull(state, model, %{status: "failed", completed: 0, total: 0, error: describe(reason)})}
  end

  defp put_pull(state, model, entry) do
    state = put_in(state, [:pulls, model], entry)
    Phoenix.PubSub.broadcast(AskDrive.PubSub, @topic, {:ollama_pulls, state.pulls})
    state
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
