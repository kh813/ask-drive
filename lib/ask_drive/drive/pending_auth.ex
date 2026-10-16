defmodule AskDrive.Drive.PendingAuth do
  @moduledoc """
  Drive sync authorizations started from a desk's admin screen and not finished yet
  (spec F-352), kept in memory by their `state`: the PKCE verifier, the redirect URI and the
  desk. Whichever comes first finishes it — Google bringing the browser back to AskDrive's
  callback (no session needed: the state is the proof, the verifier never left the server),
  or the administrator pasting the address. An entry lives 15 minutes and is used once.
  """
  use GenServer

  @table __MODULE__
  @ttl 15 * 60

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, nil}
  end

  @doc "Remembers an authorization: `%{verifier:, redirect_uri:, app:}` under its state."
  def put(state, %{} = auth) do
    if table?(), do: :ets.insert(@table, {state, auth, now() + @ttl})
    :ok
  end

  @doc "The authorization for `state`, removed so it can't be used twice; nil if none."
  def take(state) when is_binary(state) do
    with true <- table?(),
         [{^state, auth, expires}] <- :ets.take(@table, state),
         true <- now() < expires do
      auth
    else
      _ -> nil
    end
  end

  def take(_), do: nil

  @doc "Whether `state` is a pending authorization (without using it)."
  def pending?(state) when is_binary(state) do
    table?() and :ets.member(@table, state)
  end

  def pending?(_), do: false

  defp table?, do: :ets.whereis(@table) != :undefined
  defp now, do: System.system_time(:second)
end
