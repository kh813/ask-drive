defmodule AskDrive.Runtime.Mode do
  @moduledoc """
  GenServer for managing system runtime phase modes and LLM model residency.

  Three phases:
  - `:daytime` (07:00 - 19:00 default): Embedding model kept resident (`keep_alive: -1`), text generation disabled.
  - `:standby` (19:00 - 02:00 default): All models unloaded (`keep_alive: 0`), text generation disabled.
  - `:night_batch` (02:00 - 06:30 default): Generation enabled, models swapped per pipeline phase with strict single-model residency.
  """
  use GenServer
  require Logger

  alias AskDrive.LLM.Ollama
  alias AskDrive.Settings

  @valid_modes [:daytime, :standby, :night_batch]

  # --- Client API ---

  @doc """
  Starts the Runtime.Mode server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current runtime mode (`:daytime`, `:standby`, or `:night_batch`).
  """
  def current_mode do
    GenServer.call(__MODULE__, :get_mode)
  end

  @doc """
  Sets the runtime mode manually (e.g. for testing, manual batch trigger, or transition).
  """
  def set_mode(mode) when mode in @valid_modes do
    GenServer.call(__MODULE__, {:set_mode, mode})
  end

  @doc """
  Checks if text generation by LLM is permitted in the current mode.
  Returns `:ok` or `{:error, :generation_disabled}`.
  """
  def check_generation_allowed do
    GenServer.call(__MODULE__, :check_generation_allowed)
  end

  @doc """
  Forces re-evaluation of current mode based on system time and configured business hours.
  """
  def sync_with_clock do
    GenServer.call(__MODULE__, :sync_with_clock)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    # Calculate mode based on current time
    initial_mode = calculate_current_mode()
    Logger.info("AskDrive.Runtime.Mode initialized with mode: #{initial_mode}")

    # Transition into initial mode
    apply_mode_transition(nil, initial_mode)

    # Schedule clock check every 1 minute
    schedule_clock_tick()

    {:ok, %{mode: initial_mode}}
  end

  @impl true
  def handle_call(:get_mode, _from, state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_call({:set_mode, new_mode}, _from, state) do
    if state.mode != new_mode do
      Logger.info("Runtime mode transitioning from #{state.mode} to #{new_mode}")
      apply_mode_transition(state.mode, new_mode)
    end

    {:reply, :ok, %{state | mode: new_mode}}
  end

  @impl true
  def handle_call(:check_generation_allowed, _from, state) do
    setting = Settings.get_setting()
    allow_daytime = setting && setting.daytime_llm_enabled

    case state.mode do
      :night_batch ->
        {:reply, :ok, state}

      _other ->
        if allow_daytime do
          {:reply, :ok, state}
        else
          {:reply, {:error, :generation_disabled}, state}
        end
    end
  end

  @impl true
  def handle_call(:sync_with_clock, _from, state) do
    # Only auto-switch if not currently running a batch or if clock indicates phase change
    calculated = calculate_current_mode()

    new_state =
      if calculated != state.mode and state.mode != :night_batch do
        Logger.info("Clock sync triggered mode change from #{state.mode} to #{calculated}")
        apply_mode_transition(state.mode, calculated)
        %{state | mode: calculated}
      else
        state
      end

    {:reply, new_state.mode, new_state}
  end

  @impl true
  def handle_info(:clock_tick, state) do
    calculated = calculate_current_mode()

    new_state =
      if calculated != state.mode and state.mode != :night_batch do
        Logger.info("Clock tick auto-transitioning from #{state.mode} to #{calculated}")
        apply_mode_transition(state.mode, calculated)
        %{state | mode: calculated}
      else
        state
      end

    schedule_clock_tick()
    {:noreply, new_state}
  end

  # --- Internal Helpers ---

  defp schedule_clock_tick do
    Process.send_after(self(), :clock_tick, 60_000)
  end

  def calculate_current_mode(now \\ DateTime.utc_now()) do
    # Convert to local time or use UTC hour based on settings
    hour = now.hour
    setting = Settings.get_setting()

    batch_start = (setting && setting.batch_start_hour) || 2
    batch_end = (setting && setting.batch_end_hour) || 7

    cond do
      # Night batch window (e.g. 02:00 to 07:00)
      in_hour_range?(hour, batch_start, batch_end) ->
        :night_batch

      # Daytime business hours (e.g. 07:00 to 19:00)
      in_hour_range?(hour, 7, 19) ->
        :daytime

      # Standby window (e.g. 19:00 to 02:00)
      true ->
        :standby
    end
  end

  defp in_hour_range?(hour, start_h, end_h) do
    if start_h <= end_h do
      hour >= start_h and hour < end_h
    else
      # Spans midnight (e.g. 21 to 7)
      hour >= start_h or hour < end_h
    end
  end

  defp apply_mode_transition(_old_mode, :daytime) do
    setting = Settings.get_setting()

    if setting do
      # 1. Unload generation model to guarantee RAM headroom (R-103)
      Ollama.unload_model(setting.batch_model)

      # 2. Pre-warm and keep embedding model resident (R-104)
      # Calling embed with keep_alive: -1
      Task.start(fn ->
        try do
          Ollama.embed(setting.embed_model, ["prewarm"])
        rescue
          _ -> :ok
        end
      end)
    end

    :ok
  end

  defp apply_mode_transition(_old_mode, :standby) do
    setting = Settings.get_setting()

    if setting do
      # Unload both generation and embedding models
      Ollama.unload_model(setting.batch_model)
      Ollama.unload_model(setting.embed_model)
    end

    :ok
  end

  defp apply_mode_transition(_old_mode, :night_batch) do
    # Handled phase-by-phase in AskDrive.Batch.Scheduler
    :ok
  end
end
