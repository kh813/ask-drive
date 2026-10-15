defmodule AskDriveWeb.OllamaPanel do
  @moduledoc """
  The platform admin screen's Ollama card (spec F-837): whether AskDrive's own Ollama is
  installed and running, which desks need it, and installing it from here. Events go to
  `AskDriveWeb.AdminLive` (`install_ollama`, `start_ollama`, `refresh_ollama`).
  """
  use AskDriveWeb, :html

  attr :status, :map, required: true, doc: "`AskDrive.LLM.OllamaServer.status/1`"

  attr :needed, :list,
    required: true,
    doc: "`OllamaModels.required_all/0`: `[{app, role, model}]`"

  attr :install, :map, required: true, doc: "`AskDrive.LLM.OllamaInstaller.status/0`"
  attr :starting, :boolean, default: false

  def ollama_card(assigns) do
    assigns =
      assigns
      |> assign(:installed?, is_binary(assigns.status.installed))
      |> assign(:running?, match?({:ok, _}, assigns.status.running))
      |> assign(:installing?, assigns.install.status == :installing)

    ~H"""
    <div
      id="ollama-runtime"
      class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
    >
      <div>
        <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
          <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" />
          {gettext("Ollama (local inference)")}
        </h2>
        <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
          {gettext(
            "AskDrive's own Ollama runs models on this server, shared by every desk: the embedding (search), and generation when a desk runs it locally. It isn't needed while every desk uses cloud APIs. Embedding runs well enough without a GPU; generating on a server without one is slow."
          )}
        </p>
      </div>

      <dl class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
        <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
          <dt class="text-zinc-400">{gettext("Installed")}</dt>
          <dd id="ollama-installed" class="mt-1 font-semibold">
            <%= if @status.installed do %>
              <span class="text-emerald-600">{gettext("Installed already")}</span>
              <span class="block font-mono font-normal text-[11px] text-zinc-500 break-all">
                {@status.installed}
              </span>
            <% else %>
              <span class="text-amber-600">{gettext("Not installed")}</span>
            <% end %>
          </dd>
        </div>
        <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
          <dt class="text-zinc-400">{gettext("Running")}</dt>
          <dd id="ollama-running" class="mt-1 font-semibold">
            <%= case @status.running do %>
              <% {:ok, version} -> %>
                <span class="text-emerald-600">{gettext("Running (%{version})", version: version)}</span>
              <% _ -> %>
                <span class="text-zinc-500">{gettext("Not running")}</span>
            <% end %>
          </dd>
        </div>
        <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
          <dt class="text-zinc-400">{gettext("Used by")}</dt>
          <dd id="ollama-needed" class="mt-1">
            <%= if @needed == [] do %>
              <span class="text-zinc-500">{gettext("No desk uses Ollama")}</span>
            <% else %>
              <ul class="space-y-0.5">
                <li :for={{app, role, model} <- @needed}>
                  {app.name}: {role} <span class="font-mono text-zinc-500">({model})</span>
                </li>
              </ul>
            <% end %>
          </dd>
        </div>
      </dl>

      <p
        :if={@needed != [] and not @installed?}
        id="ollama-needed-warning"
        class="p-3 rounded-xl bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800/50 text-amber-800 dark:text-amber-200 text-xs leading-relaxed"
      >
        {gettext(
          "A desk is set to use Ollama but it isn't installed: its nightly batch can't ingest documents, and search doesn't work. Install it below."
        )}
      </p>

      <p :if={not @install.available?} class="text-xs text-zinc-500">
        {gettext("AskDrive doesn't manage Ollama on this server (started without app.sh).")}
      </p>

      <div :if={@install.available?} class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          id="install-ollama-btn"
          phx-click="install_ollama"
          disabled={@installing?}
          data-confirm={
            if(@installed?,
              do:
                gettext(
                  "Reinstall Ollama? It downloads it again (around 1 GB or more) and restarts it; chats that are summarizing with it may fail meanwhile."
                ),
              else:
                gettext(
                  "Install Ollama? It downloads around 1 GB or more into this server's AskDrive folder; it can take several minutes."
                )
            )
          }
          class="px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition disabled:opacity-50 disabled:cursor-wait"
        >
          <.icon
            name={if(@installing?, do: "hero-arrow-path", else: "hero-arrow-down-tray")}
            class={["w-4 h-4 inline", @installing? && "animate-spin"]}
          />
          {cond do
            @installing? -> gettext("Installing…")
            @installed? -> gettext("Reinstall Ollama")
            true -> gettext("Install Ollama")
          end}
        </button>
        <button
          :if={@installed? and not @running? and not @installing?}
          type="button"
          id="start-ollama-btn"
          phx-click="start_ollama"
          disabled={@starting}
          class="px-4 py-2 rounded-xl border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-50 dark:hover:bg-zinc-800 font-medium text-xs transition disabled:opacity-50 disabled:cursor-wait"
        >
          {if(@starting, do: gettext("Starting…"), else: gettext("Start Ollama"))}
        </button>
        <button
          type="button"
          id="refresh-ollama-btn"
          phx-click="refresh_ollama"
          class="px-3 py-2 rounded-xl text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
        >
          {gettext("Refresh")}
        </button>
      </div>

      <div :if={@install.status != :idle} id="ollama-install-status" class="space-y-2">
        <p class={[
          "text-xs font-medium",
          case @install.status do
            :done -> "text-emerald-700 dark:text-emerald-300"
            :failed -> "text-red-600"
            _ -> "text-blue-600"
          end
        ]}>
          {case @install.status do
            :installing ->
              gettext("Installing Ollama…")

            :done ->
              gettext(
                "Ollama is installed. AskDrive is starting it and pulling the models the desks need (see each desk's Settings, Local models)."
              )

            :failed ->
              gettext(
                "The install failed. See the output below; on Linux, the archive needs zstd (sudo apt-get install -y zstd on the server)."
              )
          end}
        </p>
        <p :if={@install.progress} class="text-[11px] font-mono text-zinc-500">{@install.progress}</p>
        <pre
          :if={@install.log != []}
          class="max-h-48 overflow-auto p-3 rounded-lg bg-zinc-950 text-zinc-200 text-[11px] leading-relaxed whitespace-pre-wrap"
        >{Enum.join(@install.log, "\n")}</pre>
      </div>
    </div>
    """
  end
end
