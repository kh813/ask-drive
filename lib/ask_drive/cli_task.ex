defmodule AskDrive.CliTask do
  @moduledoc """
  Shared startup for one-off `mix ask_drive.*` recovery tasks (grant_admin,
  set_admin_password, set_drive_service_account).

  These exist specifically so an operator can fix things when the running AskDrive service
  is in a bad state — but `.env.prod` always sets `PHX_SERVER=true`, so a plain `mix
  app.start` would also bind `AskDriveWeb.Endpoint` to the same port the real service (e.g.
  a launchd-managed instance) may already be listening on, and lose the race. That defeats
  the whole point of a recovery tool: the task never even reaches its `run/1` body, since
  `Mix.Task.run("app.start")` — and the supervisor tree crash a bad bind causes — happens
  before that.

  `start!/0` starts everything these tasks actually need (Repo, contexts) while explicitly
  keeping the Endpoint out of "listening" mode, so they work regardless of whether the real
  service is also running.
  """

  @doc """
  Starts the application without binding the HTTP port, then runs `fun`.
  """
  def run(fun) when is_function(fun, 0) do
    # Merge rather than replace: config/runtime.exs has already set host/port/secret_key_base
    # by the time this runs, and a bare `put_env(..., server: false)` would wipe them out.
    existing = Application.get_env(:ask_drive, AskDriveWeb.Endpoint, [])
    Application.put_env(:ask_drive, AskDriveWeb.Endpoint, Keyword.put(existing, :server, false))
    Mix.Task.run("app.start")
    fun.()
  end
end
