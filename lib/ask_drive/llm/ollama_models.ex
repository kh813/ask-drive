defmodule AskDrive.LLM.OllamaModels do
  @moduledoc """
  The models of AskDrive's own Ollama (spec F-827, F-838). Ollama runs privately for the app
  (`.runtime/bin`, not on anyone's PATH), so models are pulled through its HTTP API.

  One Ollama serves every desk and its models take gigabytes of the server's disk and memory,
  so they are the platform administrator's to manage, on the platform screen's Ollama card:
  pull a model by name (with progress), delete one no desk uses, and see the models the desks'
  settings name that aren't pulled. A desk only chooses among the pulled models; nothing is
  pulled because a desk saved its settings, nor at boot (which only records whether Ollama is
  needed and starts it if so).

  Pull progress lives in this GenServer and is broadcast on PubSub topic "ollama_models".
  """
  use GenServer
  require Logger
  use Gettext, backend: AskDriveWeb.Gettext

  alias AskDrive.{LLM, Settings}
  alias AskDrive.LLM.OllamaServer
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
  After a desk's settings change (or at boot, `:all`): records for `app.sh start` whether any
  desk uses Ollama (F-829) and, if one does, starts it when it isn't running. Pulls nothing
  (F-838). `{:ok, :not_used}`, or `{:ok, missing}` — the models the settings name that aren't
  pulled — or `{:error, reason}` when Ollama can't be asked.
  """
  def sync_needed(setting \\ Settings.get_setting!())

  def sync_needed(:all), do: sync(required_all(), Settings.platform_setting!())

  def sync_needed(setting) do
    rows = required(setting)
    OllamaServer.record_needed(required_all() != [])
    if rows == [], do: {:ok, []}, else: missing_of(Enum.map(rows, &elem(&1, 1)), setting)
  end

  defp sync(rows, setting) do
    models = rows |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
    OllamaServer.record_needed(models != [])
    if models == [], do: {:ok, :not_used}, else: missing_of(models, setting)
  end

  defp missing_of(models, setting) do
    OllamaServer.ensure_running(setting)

    with {:ok, names} <- installed(setting),
         do: {:ok, models |> Enum.uniq() |> Enum.reject(&installed?(&1, names))}
  end

  @doc """
  The platform screen's model list (F-838): the installed models
  (`Ollama.catalog/1`), each with `used_by: [{app, role}]`, and `missing: [{app, role,
  model}]` — what the desks' settings name that isn't pulled. `{:ok, map}` or `{:error, reason}`.
  """
  def overview(setting \\ Settings.platform_setting!()) do
    with {:ok, models} <- Ollama.catalog(LLM.provider_opts("ollama", setting)) do
      rows = required_all()
      names = Enum.map(models, & &1.name)

      models =
        Enum.map(models, fn model ->
          used_by =
            for {app, role, name} <- rows,
                normalize(name) == normalize(model.name),
                do: {app, role}

          Map.put(model, :used_by, used_by)
        end)

      {:ok,
       %{models: models, missing: Enum.reject(rows, fn {_, _, m} -> installed?(m, names) end)}}
    end
  end

  @doc "A desk's choice of pulled models (F-838): `Ollama.catalog/1` with the desk's endpoint."
  def catalog(setting \\ Settings.get_setting!()),
    do: Ollama.catalog(LLM.provider_opts("ollama", setting))

  @doc """
  The pull-down options for a desk's Ollama model field: only the pulled models that can do
  `kind` (`:embedding` or `:generation`; a model whose capabilities Ollama doesn't report is
  offered for both). A saved name that isn't among them can't be chosen again (F-838): the
  field asks for one of these instead.
  """
  def options(models, kind) do
    for model <- models, suits?(model, kind), do: {model.name, model.name}
  end

  @doc "The pulled model `name` refers to (a missing tag means \":latest\"), or nil."
  def find(models, name) when is_binary(name) and name != "",
    do: Enum.find(models, &(normalize(&1.name) == normalize(name)))

  def find(_models, _name), do: nil

  @doc "Whether `name` is a pulled model that can do `kind`."
  def choosable?(models, kind, name) do
    case find(models, name) do
      nil -> false
      model -> suits?(model, kind)
    end
  end

  defp suits?(model, kind) do
    wanted = if kind == :embedding, do: "embedding", else: "completion"
    model.capabilities == [] or wanted in model.capabilities
  end

  @doc """
  Deletes a pulled model no desk uses: `:ok`, `{:error, {:in_use, [app name]}}` or
  `{:error, reason}`.
  """
  def delete(model) do
    users =
      for {app, _role, name} <- required_all(),
          normalize(name) == normalize(model),
          uniq: true,
          do: app.name

    if users != [] do
      {:error, {:in_use, users}}
    else
      case Ollama.delete_model(model, LLM.provider_opts("ollama", Settings.platform_setting!())) do
        :ok ->
          Logger.info("OllamaModels: deleted #{model}")
          GenServer.call(__MODULE__, {:forget, model})
          :ok

        error ->
          error
      end
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
      {gettext("Embedding"), LLM.embedding_provider(setting), LLM.embedding_model(setting)},
      {gettext("Nightly batch (QA generation)"), LLM.generation_provider(setting),
       LLM.generation_model(setting)},
      {gettext("Chat summary"), elem(chat, 0), elem(chat, 1)}
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
      do: Process.send_after(self(), :boot_sync, @boot_delay_ms)

    {:ok, %{pulls: %{}}}
  end

  @impl true
  def handle_call(:pulls, _from, state), do: {:reply, state.pulls, state}

  def handle_call(:reset_pulls, _from, state), do: {:reply, :ok, %{state | pulls: %{}}}

  # a deleted model's finished pull would still show it as pulled
  def handle_call({:forget, model}, _from, state) do
    state = %{state | pulls: Map.delete(state.pulls, model)}
    Phoenix.PubSub.broadcast(AskDrive.PubSub, @topic, {:ollama_pulls, state.pulls})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:pull, model}, state) do
    if get_in(state.pulls, [model, :status]) in ["pulling", "starting"] do
      {:noreply, state}
    else
      server = self()
      # the one Ollama, at the platform's endpoint
      setting = Settings.platform_setting!()

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
  def handle_info(:boot_sync, state) do
    case sync_needed(:all) do
      {:ok, :not_used} ->
        Logger.info("OllamaModels: no desk uses Ollama; it is not started")

      {:ok, []} ->
        Logger.info("OllamaModels: all required models are installed")

      {:ok, missing} ->
        # pulled by the platform administrator (F-838); the platform screen lists them
        Logger.warning(
          "OllamaModels: models the desks' settings name aren't pulled: #{inspect(missing)}"
        )

      {:error, reason} ->
        Logger.warning("OllamaModels: could not list models: #{inspect(reason)}")
    end

    {:noreply, state}
  rescue
    e ->
      Logger.warning("OllamaModels: boot sync failed: #{Exception.message(e)}")
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

  # Ollama's answer for a name its library doesn't have (e.g. a cloud API's model name)
  defp describe(reason) when is_binary(reason) do
    if String.contains?(reason, "file does not exist"),
      do:
        gettext("There's no such model in Ollama's library: check the name (%{detail})",
          detail: reason
        ),
      else: reason
  end

  defp describe(reason), do: inspect(reason)
end
