defmodule AskDrive.AppsHelper do
  @moduledoc "Creates throwaway AskDrive apps (own SQLite file in a temp dir) for tests."
  import ExUnit.Callbacks, only: [on_exit: 1]

  def create_app!(slug, name \\ nil) do
    dir = Path.join(System.tmp_dir!(), "askdrive_apps_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:ask_drive, :apps_dir, dir)

    {:ok, app} = AskDrive.Apps.create(%{slug: slug, name: name || String.upcase(slug)})

    on_exit(fn ->
      AskDrive.Apps.Repos.stop_app_repo(slug)
      Application.delete_env(:ask_drive, :apps_dir)
      File.rm_rf(dir)
    end)

    app
  end
end
