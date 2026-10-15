defmodule AskDrive.LLM.OllamaInstaller do
  @moduledoc """
  Installing AskDrive's own Ollama from the platform admin screen (spec F-837), for a server
  set up without it (every desk on a cloud API at first) that later wants it — e.g. to embed
  on the server's CPU while generation runs on a cloud API.

  Runs `./app.sh install-ollama` (the same download into `.runtime` as `./app.sh setup` and
  `repair-ollama`, without their rebuild or restart) in the background, keeps its output and
  broadcasts it on `"ollama_install"` as `{:ollama_install, status}`. When it succeeds, Ollama
  is started (`OllamaServer.ensure_running/1`) and the models the desks need are pulled
  (`OllamaModels.ensure_required(:all)`).
  """
  use GenServer
  require Logger

  alias AskDrive.LLM.{OllamaModels, OllamaServer}

  @topic "ollama_install"
  @log_lines 200
  # the same as the updater's: a release's environment must not leak into app.sh's Elixir
  @unset_env ~w(BINDIR ROOTDIR EMU PROGNAME ERL_LIBS RELEASE_ROOT RELEASE_NAME RELEASE_VSN
    RELEASE_COMMAND RELEASE_PROG RELEASE_TMP RELEASE_NODE RELEASE_COOKIE RELEASE_MODE
    RELEASE_SYS_CONFIG RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_BOOT_SCRIPT
    RELEASE_BOOT_SCRIPT_CLEAN RELEASE_DISTRIBUTION)

  def topic, do: @topic

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `%{status: :idle | :installing | :done | :failed, log: [line] (oldest first), progress,
  by, started_at, finished_at, available?}` — `progress` is the download's last progress
  line; `available?` whether it can be installed from the admin screen here (app.sh).
  """
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Starts the install; `by` is who asked (for the log). `:ok`, or `{:error, :busy}` while one
  runs, or `{:error, :unavailable}` where AskDrive doesn't manage its Ollama (no `app.sh`).
  """
  def install(by), do: GenServer.call(__MODULE__, {:install, by})

  # --- GenServer ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok,
     %{
       status: :idle,
       log: [],
       progress: nil,
       by: nil,
       started_at: nil,
       finished_at: nil,
       port: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call({:install, _by}, _from, %{status: :installing} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:install, by}, _from, state) do
    case command() do
      nil ->
        {:reply, {:error, :unavailable}, state}

      {exe, args, cd} ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 4096},
            args: args,
            cd: cd,
            env: Enum.map(@unset_env, &{String.to_charlist(&1), false})
          ])

        Logger.info("OllamaInstaller: installing Ollama (asked by #{by})")

        state = %{
          state
          | status: :installing,
            log: [],
            progress: nil,
            by: by,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            port: port
        }

        broadcast(state)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state),
    do: {:noreply, state |> output(line) |> broadcast()}

  # curl's progress meter rewrites one line with \r: keep its latest state, not every step
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    progress =
      chunk
      |> String.split("\r", trim: true)
      |> List.last()
      |> then(&(&1 && clean(&1)))

    {:noreply, broadcast(%{state | progress: progress || state.progress})}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = %{state | port: nil, finished_at: DateTime.utc_now(), progress: nil}

    state =
      if code == 0 do
        Logger.info("OllamaInstaller: Ollama installed")
        after_install()
        %{state | status: :done}
      else
        Logger.warning("OllamaInstaller: the install failed (exit #{code})")
        %{state | status: :failed}
      end

    {:noreply, broadcast(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---------------------------------------------------------------------------

  # `{exe, args, cd}`, or nil where AskDrive doesn't manage its Ollama
  defp command do
    case Application.get_env(:ask_drive, :ollama_install_command) do
      {exe, args} ->
        {exe, args, File.cwd!()}

      nil ->
        root = Application.get_env(:ask_drive, :update_root) || File.cwd!()
        app_sh = Path.join(root, "app.sh")
        bash = System.find_executable("bash")

        if Application.get_env(:ask_drive, :manage_ollama, true) and File.exists?(app_sh) and
             bash,
           do: {bash, [app_sh, "install-ollama"], root},
           else: nil
    end
  end

  # Start it and pull what the desks need, off this process (a pull or a start can take long)
  defp after_install do
    if Application.get_env(:ask_drive, :manage_ollama, true) do
      Task.Supervisor.start_child(AskDrive.TaskSupervisor, fn ->
        OllamaServer.ensure_running(AskDrive.Settings.platform_setting!())
        OllamaModels.ensure_required(:all)
      end)
    end
  end

  defp output(state, line) do
    line = clean(line)

    # a progress line that ends with a newline is the download's last: keep it in the log
    if String.contains?(line, "\r") do
      last = line |> String.split("\r", trim: true) |> List.last() |> to_string()
      %{state | progress: nil, log: Enum.take([last | state.log], @log_lines)}
    else
      %{state | log: Enum.take([line | state.log], @log_lines)}
    end
  end

  defp clean(line),
    do: line |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "") |> String.trim_trailing()

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(AskDrive.PubSub, @topic, {:ollama_install, public(state)})
    state
  end

  defp public(state) do
    state
    |> Map.drop([:port])
    |> Map.update!(:log, &Enum.reverse/1)
    |> Map.put(:available?, command() != nil)
  end
end
