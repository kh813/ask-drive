defmodule AskDrive.LLM.QuotaLimiter do
  @moduledoc """
  How many cloud API generations run at once, per API key (spec F-841).

  A cloud provider's rate limits belong to the API key (or the Vertex project), not to a
  desk: the nightly batch generates for every desk on a cloud API at once, and the desks
  using the same key share its slots — one desk with its own key gets them all, two desks
  on one key get them between them. `run/3` takes a slot of `key` (see
  `AskDrive.LLM.quota_key/1`) for the length of `fun`; the slots are handed out in the
  order they were asked for, so no desk takes them all.

  The number of slots is the smallest `limit` asked for by those holding or waiting for one
  (each desk's 「同時に生成する数」); it applies to the slots handed out from then on, so a
  desk with a larger number that started first may briefly hold more. A rate limit (429) answered while in `run/3`
  (`rate_limited/0`, called by `AskDrive.LLM.Http`) halves the key's slots for every desk
  using it; after a minute without one they come back one at a time.

  A holder that dies (a stopped batch's task) gives its slot back.
  """
  use GenServer
  require Logger

  @key {__MODULE__, :key}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Runs `fun` in one of `key`'s slots (at most `limit` at once, see the moduledoc)."
  def run(key, limit, fun, server \\ __MODULE__)
      when is_integer(limit) and limit > 0 and is_function(fun, 0) do
    ref = GenServer.call(server, {:acquire, key, limit, self()}, :infinity)
    previous = Process.put(@key, {server, key})

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
      GenServer.cast(server, {:release, ref})
    end
  end

  @doc "Tells the key being used in this process (inside `run/3`) that it was rate limited."
  def rate_limited do
    case Process.get(@key) do
      {server, key} -> GenServer.cast(server, {:rate_limited, key, now()})
      nil -> :ok
    end
  end

  @doc "A key's state, for tests and the logs: `%{running:, waiting:, cap:}`."
  def info(key, server \\ __MODULE__), do: GenServer.call(server, {:info, key})

  # --- Server -------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{keys: %{}, refs: %{}}}

  @impl true
  def handle_call({:acquire, key, limit, pid}, from, state) do
    ref = Process.monitor(pid)
    entry = entry(state, key)
    entry = %{entry | waiting: :queue.in({ref, from, limit}, entry.waiting)}

    state =
      state
      |> put_in([:refs, ref], key)
      |> put_in([:keys, key], entry)
      |> grant(key)

    {:noreply, state}
  end

  def handle_call({:info, key}, _from, state) do
    entry = entry(state, key)

    {:reply,
     %{running: map_size(entry.running), waiting: :queue.len(entry.waiting), cap: entry.cap},
     state}
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, drop(state, ref)}
  end

  def handle_cast({:rate_limited, key, at}, state) do
    case state.keys do
      %{^key => entry} ->
        cap = max(1, div(max_slots(entry), 2))

        if cap < max_slots(entry),
          do: Logger.warning("Cloud API rate limited (429): #{cap} generation(s) at once for now")

        {:noreply, put_in(state, [:keys, key], %{entry | cap: cap, limited_at: at})}

      _ ->
        {:noreply, state}
    end
  end

  # a holder or a waiter died without giving its slot back
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: {:noreply, drop(state, ref)}

  defp entry(state, key) do
    Map.get(state.keys, key, %{running: %{}, waiting: :queue.new(), cap: nil, limited_at: nil})
  end

  defp drop(state, ref) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        state

      {key, refs} ->
        entry = state.keys[key]

        entry = %{
          entry
          | running: Map.delete(entry.running, ref),
            waiting: :queue.filter(fn {r, _, _} -> r != ref end, entry.waiting)
        }

        %{state | refs: refs}
        |> put_entry(key, entry)
        |> grant(key)
    end
  end

  # nothing left of a key: forget it (its slots start over next time)
  defp put_entry(state, key, %{running: running, waiting: waiting} = entry) do
    if map_size(running) == 0 and :queue.is_empty(waiting),
      do: %{state | keys: Map.delete(state.keys, key)},
      else: put_in(state, [:keys, key], entry)
  end

  # hand slots to the waiters, first come first served, while there are any
  defp grant(state, key) do
    case state.keys do
      %{^key => entry} ->
        entry = recover(entry)

        with true <- map_size(entry.running) < slots(entry),
             {{:value, {ref, from, limit}}, waiting} <- :queue.out(entry.waiting) do
          GenServer.reply(from, ref)
          entry = %{entry | running: Map.put(entry.running, ref, limit), waiting: waiting}
          state |> put_in([:keys, key], entry) |> grant(key)
        else
          _ -> put_in(state, [:keys, key], entry)
        end

      _ ->
        state
    end
  end

  # the slots: the smallest limit asked for, and lower for a while after a rate limit
  defp slots(entry),
    do: if(entry.cap, do: min(entry.cap, max_slots(entry)), else: max_slots(entry))

  defp max_slots(entry) do
    limits = Map.values(entry.running) ++ Enum.map(:queue.to_list(entry.waiting), &elem(&1, 2))
    if limits == [], do: 1, else: Enum.min(limits)
  end

  # a minute without a rate limit gives one slot back
  defp recover(%{cap: nil} = entry), do: entry

  defp recover(entry) do
    if now() - entry.limited_at >= Application.get_env(:ask_drive, :quota_recover_ms, 60_000) do
      cap = entry.cap + 1

      if cap >= max_slots(entry),
        do: %{entry | cap: nil, limited_at: nil},
        else: %{entry | cap: cap, limited_at: now()}
    else
      entry
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
