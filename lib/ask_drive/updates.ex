defmodule AskDrive.Updates do
  @moduledoc """
  Updating AskDrive from the admin screen (spec 12.8, F-1501–F-1506).

  An update is built while the server keeps serving and the batch keeps running
  (`./app.sh update --yes --build-only`, into a release beside the running one), then the
  server restarts into it: the batch is paused at its next item boundary first and continued
  after the restart (or, if chosen, the restart waits for the batch to finish). The restart is
  the service manager's: the server exits with a non-zero status and launchd / systemd start
  it again, where `./app.sh start` switches to the new release and the migrations run.

  Not a hot code upgrade: releases built with `mix release` carry no upgrade instructions,
  updates change the database schema and native dependencies, and the batch runs for hours in
  one process — Erlang keeps only two versions of a module, so a second reload would kill it.

  Every night (in the night window, before the nightly batch) the latest release is checked
  if switched on, and with automatic updating the update then runs before the batch starts.
  The work is done by `AskDrive.Updates.Server`; this module is its API and the checks.
  """
  require Logger

  alias AskDrive.{Clock, Settings}
  alias AskDrive.Runtime.Mode
  alias AskDrive.Updates.Server

  @releases_url "https://api.github.com/repos/kh813/ask-drive/releases/latest"

  @doc "The running version."
  def current_version, do: AskDrive.version()

  # --- The latest release ------------------------------------------------------------------

  @doc """
  The latest release on GitHub: `{:ok, %{version, notes, url, published_at}}` or
  `{:error, message}`.
  """
  def fetch_latest do
    opts =
      [
        url: @releases_url,
        headers: [{"accept", "application/vnd.github+json"}],
        receive_timeout: 10_000,
        retry: false
      ] ++ Application.get_env(:ask_drive, :update_req_options, [])

    case Req.get(opts) do
      {:ok, %{status: 200, body: %{"tag_name" => tag} = body}} ->
        {:ok,
         %{
           version: normalize(tag),
           notes: body["body"] || "",
           url: body["html_url"],
           published_at: body["published_at"]
         }}

      {:ok, %{status: status}} ->
        {:error, "GitHub から最新リリースを取得できませんでした（HTTP #{status}）"}

      {:error, error} ->
        {:error, "GitHub に接続できませんでした（#{Exception.message(error)}）"}
    end
  end

  @doc "Checks the latest release and keeps what was found in the platform settings."
  def check do
    result = fetch_latest()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      case result do
        {:ok, latest} -> %{update_checked_at: now, update_latest_version: latest.version}
        {:error, _} -> %{update_checked_at: now}
      end

    save_platform(attrs)
    result
  end

  @doc "Whether `version` is newer than `than` (the running version)."
  def newer?(version, than \\ current_version()) do
    with {:ok, v} <- Version.parse(normalize(version)),
         {:ok, t} <- Version.parse(normalize(than)) do
      Version.compare(v, t) == :gt
    else
      _ -> false
    end
  end

  @doc "The newer version the last check found, or nil."
  def available_version(setting \\ Settings.platform_setting()) do
    v = setting && setting.update_latest_version
    if v && newer?(v), do: v
  end

  defp normalize(version), do: version |> to_string() |> String.trim() |> String.trim_leading("v")

  # --- Every night -------------------------------------------------------------------------

  @doc """
  Whether tonight's check is due at `now` (local): switched on, in the night window, and not
  checked since the window opened.
  """
  def nightly_check_due?(setting, now \\ Clock.local_now()) do
    setting != nil and (setting.update_check_enabled or setting.update_auto_apply) and
      Mode.calculate_current_mode(now) == :night_batch and
      (is_nil(setting.update_checked_at) or
         DateTime.compare(setting.update_checked_at, Mode.night_window_start_utc(now)) == :lt)
  end

  @doc """
  Called by the clock every minute, before the nightly batch: checks once a night, and with
  automatic updating starts the update — the nightly batch then waits for it (it doesn't
  start while an update is under way).
  """
  def maybe_nightly(now \\ Clock.local_now()) do
    setting = Settings.platform_setting()

    if nightly_check_due?(setting, now) and not busy?() do
      case check() do
        {:ok, %{version: version}} ->
          if setting.update_auto_apply and newer?(version) do
            Logger.info("Updates: v#{version} found tonight; updating by itself")
            start(by: "自動アップデート", wait: :boundary, to: version)
          end

        {:error, message} ->
          Logger.warning("Updates: nightly check failed: #{message}")
      end
    end

    :ok
  rescue
    e -> Logger.error("Updates: nightly check crashed: #{Exception.message(e)}")
  end

  # --- The update ----------------------------------------------------------------------------

  @doc """
  Starts updating. `by:` who (shown and logged), `wait:` `:boundary` (pause the batch at its
  next item and continue it after the restart) or `:batch_end` (restart once no batch runs),
  `to:` the version expected.
  """
  def start(opts), do: Server.start_update(opts)

  @doc "The update in progress (or the last one): phase, versions, log, message."
  def status, do: Server.status()

  @doc "Restarts now, without waiting for the batch any longer."
  def restart_now, do: Server.restart_now()

  @doc "Cancels the build (nothing has changed in the running server yet)."
  def cancel, do: Server.cancel()

  @doc "Whether an update is being built or about to restart."
  def busy?,
    do:
      :persistent_term.get({__MODULE__, :phase}, :idle) in [
        :building,
        :waiting_batch,
        :waiting_batch_end,
        :restarting
      ]

  @doc """
  Whether the update is built and the server is about to restart: no batch starts now
  (it would only be paused again).
  """
  def restart_pending?,
    do: :persistent_term.get({__MODULE__, :phase}, :idle) in [:waiting_batch, :restarting]

  @doc false
  def put_phase(phase), do: :persistent_term.put({__MODULE__, :phase}, phase)

  @doc false
  def save_platform(attrs) do
    # get_setting! creates the row if there is none yet (a fresh install)
    AskDrive.Apps.platform(fn ->
      Settings.get_setting!() |> Ecto.Changeset.change(attrs) |> AskDrive.Repo.update()
    end)
  end
end
