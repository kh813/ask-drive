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
