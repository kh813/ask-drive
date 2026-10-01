defmodule AskDriveWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AskDriveWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Application shell: header with navigation, the signed-in user and the active LLM
  provider, plus the page content.

  Administrator rights are session-scoped, so the header shows whether the current session
  is elevated and how long it has left. The links it renders are presentation only — the
  router and `AskDriveWeb.UserAuth` are what actually enforce the boundary (N-609).

  ## Examples

      <Layouts.app flash={@flash} current_user={@current_user} admin_elevated?={@admin_elevated?}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :map, default: nil, doc: "the signed-in user, or nil"

  attr :admin_elevated?, :boolean, default: false, doc: "whether the session holds admin rights"

  attr :admin_elevation_expires_at, :any, default: nil, doc: "when the elevation lapses"

  attr :wide, :boolean, default: false, doc: "use the wider content column (admin screens)"

  attr :app, :any, default: nil, doc: "the AskDrive app this page serves (spec 6.11), or nil"
  attr :apps, :list, default: [], doc: "all apps, for the app switcher"

  attr :current, :atom,
    default: nil,
    doc: "the admin screen being shown (:app_admin or :platform_admin), to mark its link"

  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> assign(:remote_provider, remote_generation_provider())
      |> assign(:guest_mode?, AskDriveWeb.UserAuth.auth_disabled?())

    ~H"""
    <%!-- Guest mode is for getting started: everyone can reach Platform Admin, so say so on
          every screen until login is switched on (spec 6.9.6) --%>
    <div
      :if={@guest_mode?}
      id="guest-mode-banner"
      role="alert"
      class="bg-red-600 text-white text-xs"
    >
      <div class="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 py-2 flex flex-wrap items-center gap-x-3 gap-y-1">
        <span class="inline-flex items-center gap-1.5 font-semibold">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
          {gettext("Login is turned off (guest mode).")}
        </span>
        <span>{gettext("Anyone who can reach AskDrive can use Platform Admin.")}</span>
        <.link
          href={~p"/admin?tab=settings" <> "#auth-settings"}
          class="underline font-medium hover:text-red-100"
        >
          {gettext("Turn on login")}
        </.link>
      </div>
    </div>

    <header class="sticky top-0 z-40 border-b border-zinc-200 dark:border-zinc-800 bg-white/85 dark:bg-zinc-950/85 backdrop-blur">
      <div class="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 h-14 flex items-center gap-4">
        <.link navigate={~p"/"} class="flex items-center gap-2.5 shrink-0 group">
          <div class="w-8 h-8 rounded-lg bg-indigo-600 text-white flex items-center justify-center font-bold text-sm shadow-sm transition group-hover:bg-indigo-700">
            AD
          </div>
          <span class="font-bold text-sm text-zinc-900 dark:text-zinc-100">AskDrive</span>
        </.link>

        <%!-- App switcher (spec 6.11): which desk this is, and a way to the others. Switching
              is plain navigation to the other app's URL — a fresh page, nothing carried over. --%>
        <details :if={@app} id="app-switcher" class="relative">
          <summary class="list-none cursor-pointer flex items-center gap-1 px-2.5 py-1.5 rounded-lg text-sm font-semibold text-indigo-700 dark:text-indigo-300 hover:bg-indigo-50 dark:hover:bg-indigo-950/40">
            for {@app.name}
            <.icon :if={length(@apps) > 1} name="hero-chevron-down" class="w-3.5 h-3.5" />
          </summary>
          <div
            :if={length(@apps) > 1}
            class="absolute left-0 mt-1 w-64 rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shadow-lg p-1 z-50"
          >
            <p class="px-3 py-1.5 text-[11px] text-zinc-400">{gettext("Other desks")}</p>
            <a
              :for={other <- @apps}
              :if={other.slug != @app.slug}
              href={"/" <> other.slug}
              class="block px-3 py-2 rounded-lg text-sm text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800"
            >
              AskDrive for {other.name}
            </a>
            <a
              href="/"
              class="block px-3 py-2 rounded-lg text-xs text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800"
            >
              {gettext("All desks")}
            </a>
          </div>
        </details>

        <nav :if={@current_user} class="flex items-center gap-1 text-xs font-medium">
          <%!-- The chat is what everyone comes for, so it is the one that stands out --%>
          <.link
            href={if @app, do: "/" <> @app.slug, else: "/"}
            id="chat-nav-link"
            class="px-2.5 py-1.5 rounded-lg bg-zinc-100 dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100 hover:bg-zinc-200 dark:hover:bg-zinc-700 transition"
          >
            {if @app, do: gettext("Chat"), else: gettext("Desk list")}
          </.link>
          <%!-- This desk's settings only; named after the desk so it cannot be mistaken for
                Platform Admin, which lives with the admin-mode badge on the right. Only a few
                people use it, so it stays plain even while it is open. --%>
          <.link
            :if={can_access_app_admin?(@current_user, @app)}
            href={"/" <> @app.slug <> "/admin"}
            id="admin-nav-link"
            aria-current={@current == :app_admin && "page"}
            class="px-2.5 py-1.5 rounded-lg text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-zinc-800 dark:hover:text-zinc-200 transition"
          >
            <span class="hidden md:inline">{gettext("Manage %{desk}", desk: @app.name)}</span>
            <span class="md:hidden">{gettext("Desk admin")}</span>
          </.link>
        </nav>

        <div class="flex-1"></div>

        <.link
          :if={is_nil(@current_user)}
          href={~p"/login"}
          id="admin-login-link"
          class="text-[11px] px-2.5 py-1 rounded-lg text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition flex items-center gap-1"
        >
          <.icon name="hero-shield-check" class="w-3.5 h-3.5" /> {gettext("Admin login")}
        </.link>

        <%!-- Document text leaves the building when generation runs on a cloud API, so say
              so on every screen rather than burying it in settings (spec 1.2). --%>
        <span
          :if={@remote_provider}
          id="external-llm-badge"
          title={gettext("External API is used for answering. Document content is sent externally.")}
          class="hidden sm:inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-amber-50 text-amber-800 dark:bg-amber-950/50 dark:text-amber-200 border border-amber-200/60 dark:border-amber-800/50"
        >
          <.icon name="hero-cloud" class="w-3.5 h-3.5" /> {gettext("External AI: %{provider}",
            provider: @remote_provider
          )}
        </span>

        <%!-- Admin mode and what only it opens (Release, Platform Admin) form one group, so
              platform-wide settings read as part of the elevated session, not as a desk tab.
              "Platform Admin" stays in one place — right before the language switch — before
              and after elevating; before, it leads to the password prompt. --%>
        <div
          :if={@admin_elevated?}
          id="admin-mode-group"
          class="inline-flex items-stretch rounded-xl text-[11px] font-medium bg-indigo-50 text-indigo-700 dark:bg-indigo-950/60 dark:text-indigo-300 border border-indigo-200/60 dark:border-indigo-800/60 overflow-hidden"
        >
          <% remaining = remaining_label(@admin_elevation_expires_at) %>
          <span
            id="admin-mode-badge"
            title={String.trim(gettext("Admin mode") <> " " <> remaining)}
            class="inline-flex items-center gap-1.5 px-2.5 py-1"
          >
            <.icon name="hero-shield-check" class="w-3.5 h-3.5" />
            <%!-- two lines: the mode, then the time left --%>
            <span class="hidden sm:flex flex-col items-center leading-tight">
              <span>{gettext("Admin mode")}</span>
              <span :if={remaining != ""} id="admin-mode-remaining">{remaining}</span>
            </span>
          </span>
          <.link
            href={~p"/admin/release"}
            id="release-admin-link"
            class="inline-flex items-center px-2.5 py-1 border-l border-indigo-200/60 dark:border-indigo-800/60 hover:bg-indigo-100 dark:hover:bg-indigo-900/60 transition"
          >
            {gettext("Release")}
          </.link>
          <.link
            :if={is_platform_admin?(@current_user)}
            href={~p"/admin"}
            id="platform-admin-nav-link"
            aria-current={@current == :platform_admin && "page"}
            class={[
              "inline-flex items-center px-2.5 py-1 border-l border-indigo-200/60 dark:border-indigo-800/60 transition",
              if(@current == :platform_admin,
                do: "bg-indigo-600 text-white dark:bg-indigo-500",
                else: "hover:bg-indigo-100 dark:hover:bg-indigo-900/60"
              )
            ]}
          >
            {gettext("Platform Admin")}
          </.link>
        </div>

        <.link
          :if={not @admin_elevated? and is_platform_admin?(@current_user)}
          href={~p"/admin/elevate"}
          id="elevate-link"
          class="inline-flex items-center gap-1 text-[11px] font-medium px-2.5 py-1 rounded-full border border-indigo-200/60 dark:border-indigo-800/60 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-50 dark:hover:bg-indigo-950/60 transition"
        >
          <.icon name="hero-shield-check" class="w-3.5 h-3.5" /> {gettext("Platform Admin")}
        </.link>

        <.locale_switcher />

        <.theme_toggle />

        <div
          :if={@current_user}
          class="flex items-center gap-2 pl-2 border-l border-zinc-200 dark:border-zinc-800"
        >
          <div class="hidden sm:block text-right leading-tight">
            <div class="text-xs font-medium text-zinc-800 dark:text-zinc-200 max-w-[14rem] truncate">
              {@current_user.name || @current_user.email}
            </div>
            <div class="text-[10px] text-zinc-400">
              {role_label(@current_user, @admin_elevated?)}
            </div>
          </div>
          <.link
            href={~p"/logout"}
            id="logout-link"
            title={gettext("Log out")}
            class="p-1.5 rounded-lg text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition"
          >
            <.icon name="hero-arrow-left-on-rectangle" class="w-4 h-4" />
          </.link>
        </div>
      </div>
    </header>

    <main class="px-4 py-6 sm:px-6 lg:px-8">
      <div class={["mx-auto", if(@wide, do: "max-w-6xl", else: "max-w-4xl")]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  defp admin_eligible?(nil), do: false
  defp admin_eligible?(user), do: AskDrive.Accounts.any_admin_eligible?(user)

  defp is_platform_admin?(%{admin_eligible: true, status: "active"}), do: true
  defp is_platform_admin?(_), do: false

  defp can_access_app_admin?(_user, nil), do: false

  # the app's assigned administrators (F-1113); the POC guest (id 0) everywhere
  defp can_access_app_admin?(%{id: 0}, _app), do: true

  defp can_access_app_admin?(%{status: "active"} = user, %{slug: slug}),
    do: AskDrive.Accounts.assigned_app_admin?(user, slug)

  defp can_access_app_admin?(_, _), do: false

  defp role_label(_user, true), do: gettext("Administrator (Elevated)")

  defp role_label(user, _elevated?),
    do: if(admin_eligible?(user), do: gettext("User (Eligible for admin)"), else: gettext("User"))

  # Minutes left, so an operator can see at a glance whether they are about to be dropped.
  defp remaining_label(%DateTime{} = expires_at) do
    seconds = DateTime.diff(expires_at, DateTime.utc_now(), :second)

    if seconds > 0,
      do: gettext("(%{minutes} min remaining)", minutes: max(div(seconds, 60), 1)),
      else: ""
  end

  defp remaining_label(_), do: ""

  # nil when generation stays on this machine, so the banner only appears when it matters.
  defp remote_generation_provider do
    provider = AskDrive.LLM.generation_provider()

    if AskDrive.LLM.local?(provider), do: nil, else: AskDrive.LLM.label(provider)
  rescue
    _ -> nil
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  @doc """
  Provides language switcher (EN / 日本語).
  """
  attr :locale, :string, default: nil

  def locale_switcher(assigns) do
    assigns =
      assign_new(assigns, :current_locale, fn -> Gettext.get_locale(AskDriveWeb.Gettext) end)

    ~H"""
    <div
      id="locale-switcher"
      class="flex items-center text-xs font-semibold rounded-full border border-zinc-200 dark:border-zinc-700 p-0.5 bg-zinc-100 dark:bg-zinc-800"
    >
      <.link
        href={~p"/locale/en"}
        id="lang-en-btn"
        class={[
          "px-2 py-0.5 rounded-full transition text-[11px]",
          if(@current_locale == "en",
            do: "bg-white dark:bg-zinc-900 text-indigo-600 dark:text-indigo-400 shadow-xs font-bold",
            else: "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
          )
        ]}
      >
        EN
      </.link>
      <.link
        href={~p"/locale/ja"}
        id="lang-ja-btn"
        class={[
          "px-2 py-0.5 rounded-full transition text-[11px]",
          if(@current_locale == "ja",
            do: "bg-white dark:bg-zinc-900 text-indigo-600 dark:text-indigo-400 shadow-xs font-bold",
            else: "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
          )
        ]}
      >
        JA
      </.link>
    </div>
    """
  end
end
