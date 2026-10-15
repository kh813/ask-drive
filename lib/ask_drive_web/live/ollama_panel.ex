defmodule AskDriveWeb.OllamaPanel do
  @moduledoc """
  The platform admin screen's Ollama card (spec F-837, F-838): whether AskDrive's own Ollama
  is installed and running, which desks need it, installing it from here, and its models —
  pulled, pulled by name, deleted, and those the desks' settings name that aren't pulled.
  Desks only choose among the pulled models. Events go to `AskDriveWeb.AdminLive`
  (`install_ollama`, `start_ollama`, `refresh_ollama`, `pull_model`, `pull_missing_models`,
  `delete_model`).
  """
  use AskDriveWeb, :html

  attr :status, :map, required: true, doc: "`AskDrive.LLM.OllamaServer.status/1`"

  attr :needed, :list,
    required: true,
    doc: "`OllamaModels.required_all/0`: `[{app, role, model}]`"

  attr :install, :map, required: true, doc: "`AskDrive.LLM.OllamaInstaller.status/0`"
  attr :starting, :boolean, default: false

  attr :overview, :any,
    required: true,
    doc: "`OllamaModels.overview/0`: `{:ok, %{models, missing}}` or `{:error, reason}`"

  attr :pulls, :map, required: true, doc: "`OllamaModels.pulls/0`"

  # offered when typing a model to pull (any name from the Ollama library can be typed)
  @suggested [
    {"bge-m3", gettext_noop("embedding (search), multilingual")},
    {"qwen3:4b-instruct-2507-q4_K_M", gettext_noop("generation, no thinking")},
    {"qwen3:4b", gettext_noop("generation, thinking")}
  ]

  def ollama_card(assigns) do
    assigns =
      assigns
      |> assign(:installed?, is_binary(assigns.status.installed))
      |> assign(:running?, match?({:ok, _}, assigns.status.running))
      |> assign(:installing?, assigns.install.status == :installing)
      |> assign(:suggested, @suggested)

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

      <div class="flex flex-wrap items-center gap-2">
        <button
          :if={@install.available?}
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
          :if={@install.available? and @installed? and not @running? and not @installing?}
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

      <.models
        :if={@running?}
        overview={@overview}
        pulls={@pulls}
        suggested={@suggested}
      />
    </div>
    """
  end

  attr :overview, :any, required: true
  attr :pulls, :map, required: true
  attr :suggested, :list, required: true

  # Ollama's models (F-838): what's pulled and who uses it, what's missing, pulling by name
  defp models(assigns) do
    ~H"""
    <div
      id="ollama-models-admin"
      class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3"
    >
      <h3 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200 flex items-center gap-2">
        <.icon name="hero-cube" class="w-4 h-4 text-indigo-600" />
        {gettext("Models")}
      </h3>
      <p class="text-[11px] text-zinc-500 leading-relaxed">
        {gettext(
          "Desks choose their Ollama models among the ones pulled here; a desk can't pull one itself. A model takes from a few hundred MB to several GB of disk."
        )}
      </p>

      <%= case @overview do %>
        <% {:error, reason} -> %>
          <p class="text-xs text-red-600">
            {gettext("Cannot connect to Ollama: %{reason}", reason: inspect(reason))}
          </p>
        <% {:ok, %{models: models, missing: missing}} -> %>
          <div
            :if={missing != []}
            id="ollama-missing-models"
            class="p-3 rounded-xl bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800/50 text-amber-800 dark:text-amber-200 text-xs space-y-2"
          >
            <p class="font-medium">
              {gettext("Models the desks' settings name but that aren't pulled:")}
            </p>
            <ul class="space-y-1">
              <li :for={{app, role, model} <- missing} data-missing={model}>
                {app.name}: {role} — <span class="font-mono">{model}</span>
                <a
                  href={"/" <> app.slug <> "/admin?tab=settings"}
                  class="ml-1 underline text-indigo-700 dark:text-indigo-300"
                >
                  {gettext("Open the desk's settings")}
                </a>
                <span :if={not_in_library?(@pulls, model)} class="block text-[11px]">
                  {gettext(
                    "Ollama has no model by this name (perhaps a cloud API's model name left over): choose a pulled model in the desk's settings."
                  )}
                </span>
              </li>
            </ul>
            <button
              :if={Enum.any?(missing, fn {_, _, m} -> not not_in_library?(@pulls, m) end)}
              type="button"
              id="pull-missing-models-btn"
              phx-click="pull_missing_models"
              class="px-3 py-1.5 rounded-lg bg-amber-600 hover:bg-amber-700 text-white font-medium transition"
            >
              {gettext("Pull them all")}
            </button>
          </div>

          <div class="overflow-x-auto">
            <table
              id="ollama-model-table"
              class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
            >
              <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                <tr>
                  <th class="py-2 px-2">{gettext("Model")}</th>
                  <th class="py-2 px-2">{gettext("Used for")}</th>
                  <th class="py-2 px-2 text-right">{gettext("Size")}</th>
                  <th class="py-2 px-2">{gettext("Used by")}</th>
                  <th class="py-2 px-2"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                <tr :if={models == []}>
                  <td colspan="5" class="py-3 px-2 text-zinc-400">
                    {gettext("No model is pulled yet.")}
                  </td>
                </tr>
                <tr :for={model <- models} data-model={model.name}>
                  <td class="py-2 px-2 font-mono">{model.name}</td>
                  <td class="py-2 px-2">{kind_label(model.capabilities)}</td>
                  <td class="py-2 px-2 text-right whitespace-nowrap">{format_size(model.size)}</td>
                  <td class="py-2 px-2">
                    <%= if model.used_by == [] do %>
                      <span class="text-zinc-400">—</span>
                    <% else %>
                      <span :for={{app, role} <- model.used_by} class="block">{app.name}: {role}</span>
                    <% end %>
                  </td>
                  <td class="py-2 px-2 text-right">
                    <button
                      type="button"
                      phx-click="delete_model"
                      phx-value-model={model.name}
                      disabled={model.used_by != []}
                      title={if(model.used_by != [], do: gettext("A desk uses it"))}
                      data-confirm={
                        gettext("Delete %{model}? A desk can't choose it any more.",
                          model: model.name
                        )
                      }
                      class="text-red-600 hover:underline disabled:text-zinc-300 disabled:no-underline disabled:cursor-not-allowed"
                    >
                      {gettext("Delete")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
      <% end %>

      <div :if={@pulls != %{}} id="ollama-pulls" class="space-y-1 text-xs">
        <p :for={{model, pull} <- @pulls} data-pull={model}>
          <span class="font-mono">{model}</span>:
          <%= case pull.status do %>
            <% status when status in ["starting", "pulling"] -> %>
              <span class="text-blue-600">
                {gettext("Pulling")}{if p = pull_percent(pull), do: " #{p}%"}
              </span>
            <% "done" -> %>
              <span class="text-emerald-600">{gettext("Pulled")}</span>
            <% _ -> %>
              <span class="text-red-600">{gettext("Pull failed: %{error}",
                error: to_string(pull.error)
              )}</span>
          <% end %>
        </p>
      </div>

      <form id="pull-model-form" phx-submit="pull_model" class="flex flex-wrap items-center gap-2">
        <input
          type="text"
          name="model"
          list="ollama-model-suggestions"
          autocomplete="off"
          placeholder={gettext("Model name, e.g. bge-m3")}
          class="flex-1 min-w-[16rem] px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-xs font-mono"
        />
        <datalist id="ollama-model-suggestions">
          <option :for={{name, note} <- @suggested} value={name}>
            {Gettext.gettext(AskDriveWeb.Gettext, note)}
          </option>
        </datalist>
        <button
          type="submit"
          class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium transition"
        >
          {gettext("Pull model")}
        </button>
      </form>
    </div>
    """
  end

  @doc false
  # a pull Ollama refused because its library has no such name: pulling it again won't help
  def not_in_library?(pulls, model) do
    case Map.get(pulls, model) do
      %{status: "failed", error: error} when is_binary(error) ->
        String.contains?(error, "file does not exist")

      _ ->
        false
    end
  end

  defp kind_label(caps) do
    cond do
      caps == [] -> gettext("Unknown")
      "embedding" in caps and "completion" in caps -> gettext("Embedding and generation")
      "embedding" in caps -> gettext("Embedding")
      true -> gettext("Generation")
    end
  end

  defp format_size(bytes) when is_integer(bytes) and bytes >= 1_000_000_000,
    do: "#{Float.round(bytes / 1_000_000_000, 1)} GB"

  defp format_size(bytes) when is_integer(bytes), do: "#{div(bytes, 1_000_000)} MB"
  defp format_size(_), do: "—"

  defp pull_percent(%{completed: c, total: t}) when is_integer(t) and t > 0, do: div(c * 100, t)
  defp pull_percent(_), do: nil
end
