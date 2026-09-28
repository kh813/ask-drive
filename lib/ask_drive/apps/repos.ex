defmodule AskDrive.Apps.Repos do
  @moduledoc """
  Starts and tracks one `AskDrive.Repo` instance per non-primary app (spec 6.11), each on
  its own SQLite file, migrated to the current schema at start.

  At boot it persists the primary app row and brings every app's database up before the
  endpoint starts serving. Repo pids are kept in an ETS table for lock-free lookups; a repo
  that dies is restarted (and re-registered) by this server.
  """
  use GenServer
  require Logger

  alias AskDrive.{Apps, Repo}

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The repo pid for `slug` (raises if the app's database isn't running)."
  def lookup!(slug) do
    case :ets.lookup(@table, slug) do
      [{^slug, pid, _path}] -> pid
      [] -> raise "AskDrive app database not started: #{slug}"
    end
  end

  def start_app_repo(slug, path), do: GenServer.call(__MODULE__, {:start, slug, path}, 120_000)
  def stop_app_repo(slug), do: GenServer.call(__MODULE__, {:stop, slug})

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    if Application.get_env(:ask_drive, :apps_boot, true) do
      Apps.ensure_primary!()

      for app <- Apps.list(), not app.primary, app.db_path do
        case start_repo(app.slug, app.db_path) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error("Apps: could not start #{app.slug}: #{inspect(reason)}")
        end
      end
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:start, slug, path}, _from, state) do
    {:reply, start_repo(slug, path), state}
  end

  def handle_call({:stop, slug}, _from, state) do
    case :ets.lookup(@table, slug) do
      [{^slug, pid, _}] ->
        # delete first, so the :DOWN that follows isn't taken for a crash to restart
        :ets.delete(@table, slug)
        Supervisor.stop(pid)

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case :ets.match_object(@table, {:_, pid, :_}) do
      [{slug, ^pid, path}] ->
        Logger.warning("Apps: database of #{slug} went down (#{inspect(reason)}); restarting")
        :ets.delete(@table, slug)
        start_repo(slug, path)

      [] ->
        :ok
    end

    {:noreply, state}
  end

  defp start_repo(slug, path) do
    opts =
      [name: nil, database: path, pool_size: 3]
      |> Keyword.merge(Application.get_env(:ask_drive, :app_repo_opts, []))

    # Started unlinked and monitored: one app's database failing mustn't take the others
    # (or this server) down; the monitor restarts it
    with {:ok, pid} <- start_unlinked(opts),
         :ok <- migrate(pid) do
      Process.monitor(pid)
      :ets.insert(@table, {slug, pid, path})
      {:ok, pid}
    end
  end

  defp start_unlinked(opts) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        case Repo.start_link(opts) do
          {:ok, repo} ->
            Process.unlink(repo)
            send(parent, {:repo, self(), {:ok, repo}})

          error ->
            send(parent, {:repo, self(), error})
        end
      end)

    receive do
      {:repo, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      60_000 -> {:error, :timeout}
    end
  end

  defp migrate(pid) do
    Ecto.Migrator.run(Repo, migrations(), :up, all: true, dynamic_repo: pid, log: false)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The migration modules, loaded once. Handing Ecto the path instead would recompile every
  # migration file for every app database ("redefining module ..." warnings at each boot).
  defp migrations do
    case :persistent_term.get({__MODULE__, :migrations}, nil) do
      nil ->
        list =
          Ecto.Migrator.migrations_path(Repo)
          |> Path.join("*.exs")
          |> Path.wildcard()
          |> Enum.sort()
          |> Enum.map(fn file ->
            [version | _] = file |> Path.basename() |> String.split("_", parts: 2)
            {String.to_integer(version), load_migration(file)}
          end)

        :persistent_term.put({__MODULE__, :migrations}, list)
        list

      list ->
        list
    end
  end

  defp load_migration(file) do
    [_, name] = Regex.run(~r/defmodule\s+([\w.]+)/, File.read!(file))
    module = Module.concat([name])

    if Code.ensure_loaded?(module) do
      module
    else
      file |> Code.require_file() |> Enum.find_value(fn {mod, _} -> mod == module && mod end)
    end
  end
end
