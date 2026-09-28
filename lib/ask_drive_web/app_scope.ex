defmodule AskDriveWeb.AppScope do
  @moduledoc """
  LiveView `on_mount` hook for `/:app` routes (spec 6.11): resolves the app from the URL,
  points the LiveView process at its database for the lifetime of the page, and assigns
  `:app`, `:apps` (for the switcher) and `:base_path` ("/it-support").

  The app is fixed for the page: switching apps is navigating to another URL, i.e. a new
  LiveView — so nothing in flight can land in the wrong app.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias AskDrive.Apps

  def on_mount(:app, %{"app" => slug}, _session, socket) do
    case Apps.get_by_slug(slug) do
      nil ->
        {:halt,
         socket
         |> put_flash(:error, "窓口「#{slug}」は見つかりません。")
         |> redirect(to: "/")}

      app ->
        Apps.put_current(app)

        {:cont,
         socket
         |> assign(:app, app)
         |> assign(:apps, Apps.list())
         |> assign(:base_path, "/" <> app.slug)}
    end
  end
end
