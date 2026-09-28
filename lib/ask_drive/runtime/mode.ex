defmodule AskDrive.Runtime.Mode do
  @moduledoc """
  GenServer for managing system runtime phase modes and LLM model residency.

  Three phases:
  - `:daytime` (07:00 - 19:00 default): Embedding model kept resident (`keep_alive: -1`), text generation disabled.
  - `:standby` (19:00 - 02:00 default): All models unloaded (`keep_alive: 0`), text generation disabled.
  - `:night_batch` (02:00 - 06:30 default): Generation enabled, models swapped per pipeline phase with strict single-model residency.

  The whole mechanism exists to stop the generation and embedding models from competing for
  8GB of RAM. A provider running off-machine consumes none of it, so when generation is
  served by a remote API the phase no longer gates it (R-106), and residency control is
  skipped for a remote embedding provider too (R-107).
  """
  use GenServer
  require Logger

  alias AskDrive.LLM
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

  @doc """
  Leaves the batch: switches to whatever mode the clock calls for. `sync_with_clock/0`
  deliberately never leaves `:night_batch` (so a clock tick can't pull the rug out from under
  a running batch), which is why the batch itself must call this when it finishes.
  """
  def end_batch do
    GenServer.call(__MODULE__, :end_batch)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    # Calculate mode based on current time
    initial_mode = resting_mode(calculate_current_mode())
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
  def handle_call(:end_batch, _from, state) do
    target = resting_mode(calculate_current_mode())

    if target != state.mode do
      Logger.info("Batch finished; runtime mode transitioning from #{state.mode} to #{target}")
      apply_mode_transition(state.mode, target)
    end

    {:reply, target, %{state | mode: target}}
  end

  @impl true
  def handle_call(:check_generation_allowed, _from, state) do
    setting = Settings.get_setting()

    allowed? =
      state.mode == :night_batch or
        (setting && setting.daytime_llm_enabled) or
        not LLM.local_generation?(setting)

    if allowed? do
      {:reply, :ok, state}
    else
      {:reply, {:error, :generation_disabled}, state}
    end
  end

  @impl true
  def handle_call(:sync_with_clock, _from, state) do
    new_state = follow_clock(state, "Clock sync")
    {:reply, new_state.mode, new_state}
  end

  @impl true
  def handle_info(:clock_tick, state) do
    maybe_start_nightly_batch()
    new_state = follow_clock(state, "Clock tick")
    schedule_clock_tick()
    {:noreply, new_state}
  end

  # `:night_batch` belongs to a running batch: the scheduler enters it and leaves it via
  # end_batch/0, and the clock never touches it while a batch runs. Outside a batch the
  # night window rests in `:standby`. (The clock used to switch into `:night_batch` itself
  # and then refused to ever leave it, so the mode stuck there until a restart.)
  defp follow_clock(state, reason) do
    if state.mode == :night_batch and AskDrive.Batch.Scheduler.running?() do
      state
    else
      target = resting_mode(calculate_current_mode())

      if target != state.mode do
        Logger.info("#{reason}: runtime mode transitioning from #{state.mode} to #{target}")
        apply_mode_transition(state.mode, target)
      end

      %{state | mode: target}
    end
  end

  defp resting_mode(:night_batch), do: :standby
  defp resting_mode(mode), do: mode

  # The nightly batch (spec 6.3) had no trigger at all: nothing ever called run_batch/1
  # except the admin button. Start it from the clock once per night window. "Once" is read
  # from batch_runs, so a restart inside the window doesn't start a second one.
  defp maybe_start_nightly_batch do
    if Application.get_env(:ask_drive, :auto_nightly_batch, true) and
         calculate_current_mode() == :night_batch and
         not AskDrive.Batch.Scheduler.running?() and
         not AskDrive.Batch.Scheduler.ran_since?(night_window_start_utc()) do
      Logger.info("Night window reached: starting the nightly batch")
      Task.start(fn -> AskDrive.Batch.Scheduler.run_batch() end)
    end
  rescue
    e -> Logger.error("Could not start the nightly batch: #{Exception.message(e)}")
  end

  @doc """
  Start of the current (or most recent) night window, in UTC: today's `batch_start_hour`
  in local time, or yesterday's if that is still in the future.
  """
  def night_window_start_utc(now \\ AskDrive.Clock.local_now()) do
    setting = Settings.get_setting()
    start_h = (setting && setting.batch_start_hour) || 21
    today_start = NaiveDateTime.new!(NaiveDateTime.to_date(now), Time.new!(start_h, 0, 0))

    start =
      if NaiveDateTime.compare(now, today_start) == :lt,
        do: NaiveDateTime.add(today_start, -86_400),
        else: today_start

    AskDrive.Clock.local_to_utc(start)
  end

  # --- Internal Helpers ---

  defp schedule_clock_tick do
    Process.send_after(self(), :clock_tick, 60_000)
  end

  def calculate_current_mode(now \\ AskDrive.Clock.local_now()) do
    # Local wall-clock hour: batch hours are office hours, not UTC (see AskDrive.Clock)
    hour = now.hour
    setting = Settings.get_setting()

    # Same defaults as the settings schema (21:00-07:00)
    batch_start = (setting && setting.batch_start_hour) || 21
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
      # 1. Unload generation model to guarantee RAM headroom (R-103). A no-op for remote
      #    providers, which hold no local memory (R-106).
      LLM.unload_model(setting.batch_model, setting: setting)

      # 2. Pre-warm and keep the embedding model resident so the first question of the day
      #    does not pay the load time (R-104). Also a no-op for remote providers (R-107).
      Task.start(fn ->
        try do
          LLM.prewarm_embedding(setting.embed_model, setting: setting)
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
      LLM.unload_model(setting.batch_model, setting: setting)

      LLM.unload_model(setting.embed_model,
        setting: setting,
        provider: LLM.embedding_provider(setting)
      )
    end

    :ok
  end

  defp apply_mode_transition(_old_mode, :night_batch) do
    # Handled phase-by-phase in AskDrive.Batch.Scheduler
    :ok
  end
end
