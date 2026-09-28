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
    # config/runtime.exs turns the Endpoint's `server` on with a plain
    # `if System.get_env("PHX_SERVER") do ...` — note that this is truthy for *any* non-nil
    # string, so even PHX_SERVER=false would still enable it. Overriding the resulting
    # `:server` config with `Application.put_env/3` does not hold up: `app.start` reloads
    # runtime.exs internally as part of its own requirements regardless of whether
    # "loadconfig" already ran once in this invocation, which reapplies `server: true` and
    # clobbers the override before the supervisor tree starts (confirmed by reproducing the
    # exact port-bind crash this exists to avoid, twice, with two different override
    # strategies). Removing the env var itself is what actually survives every reload: with
    # nothing to key off, that `if` never fires, however many times it runs.
    System.delete_env("PHX_SERVER")

    Mix.Task.run("app.start")
    fun.()
  end
end
