defmodule AskDriveWeb.PortalLive do
  @moduledoc "The platform's front page: the list of AskDrive apps (spec 6.11)."
  use AskDriveWeb, :live_view

  alias AskDrive.Apps

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "AskDrive")
     |> assign(:apps, Apps.list())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      admin_elevated?={@admin_elevated?}
      admin_elevation_expires_at={@admin_elevation_expires_at}
      apps={@apps}
    >
      <div class="space-y-6">
        <div>
          <h1 class="font-bold text-2xl text-zinc-900 dark:text-zinc-100">AskDrive</h1>
          <p class="text-sm text-zinc-500 mt-1">{gettext("Select a desk to ask questions.")}</p>
        </div>

        <div id="app-list" class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <.link
            :for={app <- @apps}
            navigate={"/" <> app.slug}
            id={"app-card-#{app.slug}"}
            class="block p-5 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm hover:border-indigo-400 hover:shadow transition"
          >
            <div class="flex items-center gap-2">
              <.icon name="hero-chat-bubble-left-right" class="w-5 h-5 text-indigo-600" />
              <span class="font-semibold text-zinc-900 dark:text-zinc-100">
                AskDrive for {app.name}
              </span>
            </div>
            <p :if={app.description} class="text-xs text-zinc-500 mt-2 leading-relaxed">
              {app.description}
            </p>
            <p class="text-[11px] text-zinc-400 mt-2 font-mono">/{app.slug}</p>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
