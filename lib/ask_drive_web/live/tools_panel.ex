defmodule AskDriveWeb.ToolsPanel do
  @moduledoc """
  The 「インストールとアップデート」 tab's external programs card (spec F-839): pdftotext,
  pandoc, LibreOffice and zstd — installed or not, what for, and how to install them: from
  here when AskDrive can place the program itself (pandoc), otherwise the commands to run on
  the server, then 「再確認」. Events go to `AskDriveWeb.AdminLive` (`install_pandoc`,
  `refresh_tools`).
  """
  use AskDriveWeb, :html

  attr :tools, :list, required: true, doc: "`AskDrive.Runtime.Tools.list/0`"
  attr :pandoc_install, :map, required: true, doc: "`ToolInstaller.status(\"pandoc\")`"

  def tools_card(assigns) do
    ~H"""
    <div
      id="external-tools"
      class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
            <.icon name="hero-wrench-screwdriver" class="w-5 h-5 text-indigo-600" />
            {gettext("External programs")}
          </h2>
          <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
            {gettext(
              "Programs AskDrive uses to read documents, shared by every desk. Those it can place in its own folder are installed from here; the system's packages need the server's administrator rights, so their commands are shown to run in a terminal on the server."
            )}
          </p>
        </div>
        <button
          type="button"
          id="refresh-tools-btn"
          phx-click="refresh_tools"
          class="px-3 py-2 rounded-xl text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
        >
          {gettext("Check again")}
        </button>
      </div>

      <div class="space-y-3">
        <div
          :for={tool <- @tools}
          :if={tool.needed?}
          id={"tool-#{tool.id}"}
          class="p-4 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800 space-y-2"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <p class="text-sm font-semibold text-zinc-800 dark:text-zinc-200">
              {tool.name}
              <span class="ml-1 text-[11px] font-normal text-zinc-500">{tool.purpose}</span>
            </p>
            <span
              data-state={if(tool.path, do: "installed", else: "missing")}
              class={[
                "text-xs font-medium",
                if(tool.path, do: "text-emerald-600", else: "text-amber-600")
              ]}
            >
              {if tool.path, do: gettext("Installed"), else: gettext("Not installed")}
            </span>
          </div>

          <p :if={tool.path} class="text-[11px] font-mono text-zinc-500 break-all">
            {tool.version} — {tool.path}
          </p>

          <div :if={is_nil(tool.path)} class="space-y-2">
            <%= if tool.installer && @pandoc_install.available? do %>
              <button
                type="button"
                id={"install-#{tool.id}-btn"}
                phx-click={"install_#{tool.id}"}
                disabled={@pandoc_install.status == :installing}
                class="px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition disabled:opacity-50 disabled:cursor-wait"
              >
                {if @pandoc_install.status == :installing,
                  do: gettext("Installing…"),
                  else: gettext("Install %{name}", name: tool.name)}
              </button>
              <p class="text-[11px] text-zinc-500">
                {gettext("Or run on the server:")}
              </p>
            <% else %>
              <p class="text-[11px] text-zinc-600 dark:text-zinc-400">
                {if tool.commands == [],
                  do:
                    gettext(
                      "Install %{name} with this system's package manager, then press Check again.",
                      name: tool.name
                    ),
                  else:
                    gettext(
                      "Run on the server (in a terminal, as a user who can use sudo), then press Check again:"
                    )}
              </p>
            <% end %>
            <pre
              :if={tool.commands != []}
              class="p-3 rounded-lg bg-zinc-950 text-zinc-100 text-[11px] font-mono leading-relaxed select-all whitespace-pre-wrap"
            >{Enum.join(tool.commands, "\n")}</pre>
          </div>

          <div
            :if={tool.installer && @pandoc_install.status in [:installing, :done, :failed]}
            id={"#{tool.id}-install-status"}
            class="space-y-1"
          >
            <p class={[
              "text-xs",
              case @pandoc_install.status do
                :done -> "text-emerald-700 dark:text-emerald-300"
                :failed -> "text-red-600"
                _ -> "text-blue-600"
              end
            ]}>
              {case @pandoc_install.status do
                :installing -> gettext("Installing…")
                :done -> gettext("Installed. It's used from the next ingestion.")
                :failed -> gettext("The install failed. See the output below.")
              end}
            </p>
            <pre
              :if={@pandoc_install.log != []}
              class="max-h-40 overflow-auto p-3 rounded-lg bg-zinc-950 text-zinc-200 text-[11px] leading-relaxed whitespace-pre-wrap"
            >{Enum.join(@pandoc_install.log, "\n")}</pre>
          </div>
        </div>
      </div>

      <p class="text-[11px] text-zinc-400 leading-relaxed">
        {gettext(
          "No restart is needed: AskDrive finds a program as soon as it's installed. Once it is (after installing here, or on Check again), the documents skipped for its lack are read in the next ingestion (nightly batch, or a manual run)."
        )}
      </p>
    </div>
    """
  end
end
