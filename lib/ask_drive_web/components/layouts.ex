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

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :remote_provider, remote_generation_provider())

    ~H"""
    <header class="sticky top-0 z-40 border-b border-zinc-200 dark:border-zinc-800 bg-white/85 dark:bg-zinc-950/85 backdrop-blur">
      <div class="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 h-14 flex items-center gap-4">
        <.link navigate={~p"/"} class="flex items-center gap-2.5 shrink-0 group">
          <div class="w-8 h-8 rounded-lg bg-indigo-600 text-white flex items-center justify-center font-bold text-sm shadow-sm transition group-hover:bg-indigo-700">
            AD
          </div>
          <span class="font-bold text-sm text-zinc-900 dark:text-zinc-100">AskDrive</span>
        </.link>

        <nav :if={@current_user} class="flex items-center gap-1 text-xs font-medium">
          <.link
            navigate={~p"/"}
            class="px-2.5 py-1.5 rounded-lg text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition"
          >
            チャット
          </.link>
          <.link
            :if={@admin_elevated?}
            navigate={~p"/admin"}
            id="admin-nav-link"
            class="px-2.5 py-1.5 rounded-lg text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition"
          >
            管理
          </.link>
          <%!-- Eligible but not elevated: the way in is the password prompt, not /admin. --%>
          <.link
            :if={not @admin_elevated? and admin_eligible?(@current_user)}
            href={~p"/admin/elevate"}
            id="elevate-link"
            class="px-2.5 py-1.5 rounded-lg text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition flex items-center gap-1"
          >
            <.icon name="hero-shield-check" class="w-3.5 h-3.5" /> 管理者として操作
          </.link>
        </nav>

        <div class="flex-1"></div>

        <.link
          :if={is_nil(@current_user)}
          href={~p"/login"}
          id="admin-login-link"
          class="text-[11px] px-2.5 py-1 rounded-lg text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition flex items-center gap-1"
        >
          <.icon name="hero-shield-check" class="w-3.5 h-3.5" /> 管理者ログイン
        </.link>

        <%!-- Document text leaves the building when generation runs on a cloud API, so say
              so on every screen rather than burying it in settings (spec 1.2). --%>
        <span
          :if={@remote_provider}
          id="external-llm-badge"
          title="回答生成に外部 API を使用しています。文書本文が送信されます。"
          class="hidden sm:inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-amber-50 text-amber-800 dark:bg-amber-950/50 dark:text-amber-200 border border-amber-200/60 dark:border-amber-800/50"
        >
          <.icon name="hero-cloud" class="w-3.5 h-3.5" /> 外部AI: {@remote_provider}
        </span>

        <span
          :if={@admin_elevated?}
          id="admin-mode-badge"
          class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium bg-indigo-50 text-indigo-700 dark:bg-indigo-950/60 dark:text-indigo-300 border border-indigo-200/60 dark:border-indigo-800/60"
        >
          <.icon name="hero-shield-check" class="w-3.5 h-3.5" />
          管理者モード{remaining_label(@admin_elevation_expires_at)}
        </span>

        <.link
          :if={@admin_elevated?}
          href={~p"/admin/release"}
          id="release-admin-link"
          class="text-[11px] px-2 py-1 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-600 dark:text-zinc-300 transition"
        >
          解除
        </.link>

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
            title="ログアウト"
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

  defp admin_eligible?(%{admin_eligible: true, status: "active"}), do: true
  defp admin_eligible?(_), do: false

  defp role_label(_user, true), do: "管理者（昇格中）"

  defp role_label(user, _elevated?),
    do: if(admin_eligible?(user), do: "一般ユーザー（昇格可）", else: "一般ユーザー")

  # Minutes left, so an operator can see at a glance whether they are about to be dropped.
  defp remaining_label(%DateTime{} = expires_at) do
    seconds = DateTime.diff(expires_at, DateTime.utc_now(), :second)

    if seconds > 0, do: "（残り #{max(div(seconds, 60), 1)} 分）", else: ""
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
end
