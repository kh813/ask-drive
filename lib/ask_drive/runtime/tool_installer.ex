defmodule AskDrive.Runtime.ToolInstaller do
  @moduledoc """
  Installing the external programs AskDrive can place itself, from the platform admin
  screen's 「インストールとアップデート」 tab (spec F-837, F-839): its own Ollama, and pandoc
  (Office documents' text). Both go into `.runtime` without root, as `./app.sh setup` does;
  what needs the system's package manager (pdftotext, zstd) is shown as commands to run on
  the server instead (`AskDrive.Runtime.Tools`).

  Runs `./app.sh install-<tool>` in the background, keeps each tool's output and broadcasts
  it on `"tool_install"` as `{:tool_install, tool, status}`. After Ollama is installed it is
  started (`OllamaServer.ensure_running/1`); its models are then pulled by the platform
  administrator on the same tab (F-838).
  """
  use GenServer
  require Logger

  alias AskDrive.LLM.{OllamaModels, OllamaServer}

  @topic "tool_install"
  @tools ~w(ollama pandoc)
  @log_lines 200
  # the same as the updater's: a release's environment must not leak into app.sh's Elixir
  @unset_env ~w(BINDIR ROOTDIR EMU PROGNAME ERL_LIBS RELEASE_ROOT RELEASE_NAME RELEASE_VSN
    RELEASE_COMMAND RELEASE_PROG RELEASE_TMP RELEASE_NODE RELEASE_COOKIE RELEASE_MODE
    RELEASE_SYS_CONFIG RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_BOOT_SCRIPT
    RELEASE_BOOT_SCRIPT_CLEAN RELEASE_DISTRIBUTION)

  def topic, do: @topic
  def tools, do: @tools

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `tool`'s install: `%{status: :idle | :installing | :done | :failed, log: [line] (oldest
  first), progress, by, started_at, finished_at, available?}` — `progress` is the download's
  last progress line; `available?` whether it can be installed from the admin screen here.
  """
  def status(tool) when tool in @tools, do: GenServer.call(__MODULE__, {:status, tool})

  @doc """
  Starts installing `tool`; `by` is who asked. `:ok`, or `{:error, :busy}` while it runs, or
  `{:error, :unavailable}` where AskDrive doesn't manage its programs (no `app.sh`).
  """
  def install(tool, by) when tool in @tools, do: GenServer.call(__MODULE__, {:install, tool, by})

  # --- GenServer ---------------------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{tools: Map.new(@tools, &{&1, idle()}), ports: %{}}}

  defp idle,
    do: %{status: :idle, log: [], progress: nil, by: nil, started_at: nil, finished_at: nil}

  @impl true
  def handle_call({:status, tool}, _from, state), do: {:reply, public(tool, state), state}

  def handle_call({:install, tool, by}, _from, state) do
    cond do
      state.tools[tool].status == :installing ->
        {:reply, {:error, :busy}, state}

      command(tool) == nil ->
        {:reply, {:error, :unavailable}, state}

      true ->
        {exe, args, cd} = command(tool)

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

        Logger.info("ToolInstaller: installing #{tool} (asked by #{by})")

        entry = %{idle() | status: :installing, by: by, started_at: DateTime.utc_now()}

        state =
          %{state | ports: Map.put(state.ports, port, tool)}
          |> put_tool(tool, entry)

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, state) when is_map_key(state.ports, port) do
    tool = state.ports[port]
    {:noreply, update_tool(state, tool, &output(&1, line))}
  end

  # curl's progress meter rewrites one line with \r: keep its latest state, not every step
  def handle_info({port, {:data, {:noeol, chunk}}}, state) when is_map_key(state.ports, port) do
    progress = chunk |> String.split("\r", trim: true) |> List.last()
    progress = progress && clean(progress)

    {:noreply,
     update_tool(state, state.ports[port], fn entry ->
       %{entry | progress: progress || entry.progress}
     end)}
  end

  def handle_info({port, {:exit_status, code}}, state) when is_map_key(state.ports, port) do
    {tool, ports} = Map.pop(state.ports, port)
    state = %{state | ports: ports}

    status =
      if code == 0 do
        Logger.info("ToolInstaller: #{tool} installed")
        after_install(tool)
        :done
      else
        Logger.warning("ToolInstaller: installing #{tool} failed (exit #{code})")
        :failed
      end

    {:noreply,
     update_tool(state, tool, fn entry ->
       %{entry | status: status, progress: nil, finished_at: DateTime.utc_now()}
     end)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---------------------------------------------------------------------------

  # `{exe, args, cd}`, or nil where AskDrive doesn't manage its programs
  defp command(tool) do
    case Application.get_env(:ask_drive, :tool_install_command) do
      {exe, args} ->
        {exe, args, File.cwd!()}

      nil ->
        root = Application.get_env(:ask_drive, :update_root) || File.cwd!()
        app_sh = Path.join(root, "app.sh")
        bash = System.find_executable("bash")

        if Application.get_env(:ask_drive, :manage_ollama, true) and File.exists?(app_sh) and
             bash,
           do: {bash, [app_sh, "install-" <> tool], root},
           else: nil
    end
  end

  # Ollama: start it (and record that it's needed), off this process (a start takes a while)
  defp after_install("ollama") do
    if Application.get_env(:ask_drive, :manage_ollama, true) do
      Task.Supervisor.start_child(AskDrive.TaskSupervisor, fn ->
        OllamaServer.ensure_running(AskDrive.Settings.platform_setting!())
        OllamaModels.sync_needed(:all)
      end)
    end
  end

  defp after_install(_tool), do: :ok

  defp output(entry, line) do
    line = clean(line)

    # a progress line that ends with a newline is the download's last: keep it in the log
    if String.contains?(line, "\r") do
      last = line |> String.split("\r", trim: true) |> List.last() |> to_string()
      %{entry | progress: nil, log: Enum.take([last | entry.log], @log_lines)}
    else
      %{entry | log: Enum.take([line | entry.log], @log_lines)}
    end
  end

  defp clean(line),
    do: line |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "") |> String.trim_trailing()

  defp update_tool(state, tool, fun), do: put_tool(state, tool, fun.(state.tools[tool]))

  defp put_tool(state, tool, entry) do
    state = put_in(state, [:tools, tool], entry)

    Phoenix.PubSub.broadcast(
      AskDrive.PubSub,
      @topic,
      {:tool_install, tool, public(tool, state)}
    )

    state
  end

  defp public(tool, state) do
    state.tools[tool]
    |> Map.update!(:log, &Enum.reverse/1)
    |> Map.put(:available?, command(tool) != nil)
  end
end
