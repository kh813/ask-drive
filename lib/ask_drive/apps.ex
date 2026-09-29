defmodule AskDrive.Apps do
  @moduledoc """
  Several AskDrive apps on one platform (spec 6.11) — e.g. "IT-Support" run by the IT
  department and "HR" run by HR — each with its own Google Drive folder, Gemini key (costs
  billed separately), index, QA, question log and batch history.

  ## Isolation: one SQLite database per app

  Every app has its own database file with the full schema, and the code that answers
  questions, indexes and generates QA is unchanged: it simply runs against the current
  process's database (`Ecto.Repo.put_dynamic_repo/1`). Nothing needs an app filter in its
  queries, so nothing can forget one and mix another app's documents into an answer.

  The **primary** app (the installation as it was before apps existed) uses the platform
  database itself, so no data had to move. Platform-wide data — users, administrator
  elevation, the nightly window, the Ollama server, SSL — is read from the platform
  database explicitly (`platform/1`), whichever app a process is serving.

  ## Carrying the app into other processes

  The dynamic repo lives in the process dictionary, which spawned processes don't inherit.
  Anything started from an app context (LiveView `start_async`, `Task.start`, `spawn`) must
  wrap its function with `bind/1`.
  """
  require Logger
  import Ecto.Query, warn: false

  alias AskDrive.Apps.{App, Repos}
  alias AskDrive.Repo

  @primary_defaults %{slug: "it-support", name: "IT-Support", primary: true, position: 0}
  @app_key {__MODULE__, :current}

  # --- Context switching ------------------------------------------------------

  @doc "Runs `fun` with `app`'s database as the process's repo, restoring the previous one."
  def with_app(%App{} = app, fun) do
    prev_repo = Repo.get_dynamic_repo()
    prev_app = Process.get(@app_key)
    put_current(app)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(prev_repo)
      if prev_app, do: Process.put(@app_key, prev_app), else: Process.delete(@app_key)
    end
  end

  @doc "Makes `app` the current app of this process (a LiveView serving it, a batch task)."
  def put_current(%App{} = app) do
    Repo.put_dynamic_repo(repo_for(app))
    Process.put(@app_key, app)
    app
  end

  @doc "The app this process is serving, or nil (platform context)."
  def current, do: Process.get(@app_key)

  @doc "Runs `fun` against the platform database (users, elevation, global settings)."
  def platform(fun) do
    prev = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(Repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(prev)
    end
  end

  @doc """
  Wraps `fun` so that, run in another process, it sees the same app as the caller.
  `start_async(socket, :x, Apps.bind(fn -> ... end))`.
  """
  def bind(fun) when is_function(fun, 0) do
    case current() do
      nil -> fn -> platform(fun) end
      app -> fn -> with_app(app, fun) end
    end
  end

  @doc "Runs `fun` once per app (sequentially), returning `[{app, result}]`."
  def each(fun) when is_function(fun, 1) do
    for app <- list(), do: {app, with_app(app, fn -> fun.(app) end)}
  end

  # --- Registry -------------------------------------------------------------

  @doc "All apps, primary first. Without any row yet (fresh install, tests) the primary is virtual."
  def list do
    apps =
      platform(fn ->
        Repo.all(from a in App, order_by: [desc: a.primary, asc: a.position, asc: a.id])
      end)

    # the primary app always exists, persisted or not
    if Enum.any?(apps, & &1.primary), do: apps, else: [virtual_primary() | apps]
  rescue
    # the apps table doesn't exist yet (before the migration ran)
    _ -> [virtual_primary()]
  end

  def get_by_slug(slug) when is_binary(slug), do: Enum.find(list(), &(&1.slug == slug))
  def get_by_slug(_), do: nil

  def get_by_slug!(slug) when is_binary(slug) do
    get_by_slug(slug) || raise Ecto.NoResultsError, queryable: App
  end

  def get!(id), do: platform(fn -> Repo.get!(App, id) end)

  def primary, do: Enum.find(list(), & &1.primary) || virtual_primary()

  defp virtual_primary, do: struct(App, @primary_defaults)

  @doc "Persists the primary app row on first boot (so it can be renamed)."
  def ensure_primary! do
    platform(fn ->
      unless Repo.exists?(from a in App, where: a.primary) do
        %App{primary: true}
        |> App.changeset(Map.drop(@primary_defaults, [:primary]))
        |> Repo.insert!()
      end
    end)
  end

  @doc "The repo (name or pid) holding `app`'s data."
  def repo_for(%App{primary: true}), do: Repo
  def repo_for(%App{slug: slug}), do: Repos.lookup!(slug)

  @doc "Where a new app's database goes: next to the platform database."
  def db_path_for(slug) do
    dir =
      Application.get_env(:ask_drive, :apps_dir) ||
        Path.dirname(Repo.config()[:database] || Path.expand("ask_drive.db"))

    Path.join(dir, "askdrive_app_#{slug}.db")
  end

  # --- Management -----------------------------------------------------------

  @doc """
  Creates an app: its database (full schema), its settings (copied from the primary app with
  the Drive folder, Drive credentials and API keys left empty — those are what each app
  brings), and its registry row.
  """
  def create(attrs) do
    ensure_primary!()
    changeset = App.changeset(%App{}, attrs)

    with {:ok, draft} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- ensure_unique(draft.slug),
         path = db_path_for(draft.slug),
         {:ok, _pid} <- Repos.start_app_repo(draft.slug, path),
         {:ok, app} <-
           platform(fn ->
             changeset |> Ecto.Changeset.put_change(:db_path, path) |> Repo.insert()
           end) do
      seed_settings(app)
      Logger.info("Apps: created #{app.slug} (#{path})")
      {:ok, app}
    end
  end

  defp ensure_unique(slug) do
    if get_by_slug(slug),
      do:
        {:error,
         App.changeset(%App{}, %{slug: slug}) |> Ecto.Changeset.add_error(:slug, "は既に使われています")},
      else: :ok
  end

  # Fields each app must bring itself, cleared when copying the primary's settings
  @per_app_blank ~w(drive_folder_id drive_folder_name drive_service_account_json
                    drive_impersonate_email gemini_api_key openai_api_key anthropic_api_key
                    admin_password_hash)a

  defp seed_settings(app) do
    base =
      with_app(primary(), fn -> AskDrive.Settings.get_setting!() end)
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
      |> Map.merge(Map.new(@per_app_blank, &{&1, nil}))
      |> Map.put(:drive_auth_mode, "service_account")

    with_app(app, fn ->
      unless Repo.exists?(AskDrive.Settings.Setting) do
        Repo.insert!(struct(AskDrive.Settings.Setting, base))
      end
    end)
  end

  def update(%App{} = app, attrs) do
    platform(fn -> app |> App.changeset(Map.drop(attrs, ["slug", :slug])) |> Repo.update() end)
  end

  @doc """
  Removes an app from the platform. Its database file is kept (renamed with a timestamp) so
  a mistaken deletion can be undone by hand. The primary app can't be deleted.
  """
  def delete(%App{primary: true}), do: {:error, :primary}

  def delete(%App{} = app) do
    Repos.stop_app_repo(app.slug)

    if app.db_path && File.exists?(app.db_path) do
      stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      File.rename(app.db_path, app.db_path <> ".deleted-" <> stamp)
    end

    platform(fn -> Repo.delete(app) end)
  end
end
