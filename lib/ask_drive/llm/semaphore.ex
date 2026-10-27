defmodule AskDrive.LLM.Semaphore do
  @moduledoc """
  Concurrency controller for LLM and Embedding execution.
  Prevents memory exhaustion on RAM-constrained environments by limiting simultaneous requests.
  """
  use GenServer

  def start_link(opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)
    GenServer.start_link(__MODULE__, max_concurrency, name: __MODULE__)
  end

  @doc """
  For text generation: in a slot when it runs on this machine (Ollama / LM Studio, whose
  memory and CPU allow one at a time); on a cloud API, where requests mostly wait on the
  network and several can be in flight (F-840), in one of its API key's slots, shared with
  the other desks using the same key (F-841, `AskDrive.LLM.QuotaLimiter`).
  """
  def generation(fun) when is_function(fun, 0) do
    setting = AskDrive.Settings.get_setting()

    if AskDrive.LLM.local_generation?(setting) do
      run(fun)
    else
      AskDrive.LLM.QuotaLimiter.run(
        AskDrive.LLM.quota_key(setting),
        AskDrive.LLM.generation_concurrency(setting),
        fun
      )
    end
  end

  @doc """
  Runs the given function within a concurrency-controlled slot.
  """
  def run(fun, timeout \\ 300_000) when is_function(fun, 0) do
    :ok = GenServer.call(__MODULE__, :acquire, timeout)

    try do
      fun.()
    after
      GenServer.cast(__MODULE__, :release)
    end
  end

  @impl true
  def init(max_concurrency) do
    {:ok, %{max: max_concurrency, current: 0, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:acquire, from, %{current: current, max: max, waiting: waiting} = state) do
    if current < max do
      {:reply, :ok, %{state | current: current + 1}}
    else
      {:noreply, %{state | waiting: :queue.in(from, waiting)}}
    end
  end

  @impl true
  def handle_cast(:release, %{current: current, waiting: waiting} = state) do
    case :queue.out(waiting) do
      {{:value, from}, new_waiting} ->
        GenServer.reply(from, :ok)
        {:noreply, %{state | waiting: new_waiting}}

      {:empty, _} ->
        {:noreply, %{state | current: max(0, current - 1)}}
    end
  end
end
