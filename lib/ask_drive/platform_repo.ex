defmodule AskDrive.PlatformRepo do
  @moduledoc """
  `AskDrive.Repo` pinned to the platform database (spec 6.11), for platform-wide data —
  administrator elevation, its audit log — used from processes that may be serving an app.
  """
  alias AskDrive.{Apps, Repo}

  def all(q, opts \\ []), do: Apps.platform(fn -> Repo.all(q, opts) end)
  def one(q, opts \\ []), do: Apps.platform(fn -> Repo.one(q, opts) end)
  def get(q, id, opts \\ []), do: Apps.platform(fn -> Repo.get(q, id, opts) end)
  def get_by(q, clauses, opts \\ []), do: Apps.platform(fn -> Repo.get_by(q, clauses, opts) end)
  def exists?(q, opts \\ []), do: Apps.platform(fn -> Repo.exists?(q, opts) end)
  def insert(cs, opts \\ []), do: Apps.platform(fn -> Repo.insert(cs, opts) end)
  def update(cs, opts \\ []), do: Apps.platform(fn -> Repo.update(cs, opts) end)
  def delete(s, opts \\ []), do: Apps.platform(fn -> Repo.delete(s, opts) end)

  def update_all(q, updates, opts \\ []),
    do: Apps.platform(fn -> Repo.update_all(q, updates, opts) end)
end
