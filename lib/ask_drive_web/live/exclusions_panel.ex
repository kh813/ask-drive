defmodule AskDriveWeb.ExclusionsPanel do
  @moduledoc """
  The documents tab's files and folders left out of the nightly batch (spec F-358): the
  list (who left each out and when, 「対象に戻す」), a field to leave one out by its Drive URL,
  and the per-row menu of the documents list (this file, or one of the folders it sits in).
  Events go to `AskDriveWeb.AdminLive`.
  """
  use AskDriveWeb, :html

  alias AskDrive.Documents

  attr :exclusions, :list, required: true
  attr :form, :any, required: true
  attr :busy?, :boolean, default: false, doc: "this desk's batch is running"

  def exclusions_card(assigns) do
    ~H"""
    <div
      id="exclusions"
      class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
    >
      <div>
        <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center justify-between gap-2">
          <span class="flex items-center gap-2">
            <.icon name="hero-no-symbol" class="w-5 h-5 text-zinc-500" />
            {gettext("Left out of the nightly batch")}
          </span>
          <span class="text-xs font-normal text-zinc-500">
            {gettext("%{count} in total", count: length(@exclusions))}
          </span>
        </h2>
        <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
          {gettext(
            "Files and folders in the sync folder that should not answer questions, such as old versions, drafts or lists with personal information. They are never downloaded, and what was already indexed (excerpts, QA pairs, summaries) is removed at once. A folder takes everything below it. They are kept by Drive ID, so renaming does not bring them back."
          )}
        </p>
      </div>

      <p
        :if={@busy?}
        id="exclusions-busy"
        class="text-xs px-3 py-2 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 flex items-center gap-1.5"
      >
        <.icon name="hero-clock" class="w-4 h-4 shrink-0" />
        {gettext("The batch is running. Exclusions can be changed once it finishes (or is stopped).")}
      </p>

      <.form
        for={@form}
        id="exclusion-form"
        phx-submit="add_exclusion"
        class="flex flex-col sm:flex-row sm:items-end gap-2"
      >
        <div class="flex-1">
          <.input
            field={@form[:target]}
            type="text"
            label={gettext("Leave out by Drive URL")}
            placeholder={gettext("URL of a file or folder in the sync folder (or its ID)")}
            autocomplete="off"
          />
        </div>
        <button
          type="submit"
          id="add-exclusion-btn"
          disabled={@busy?}
          phx-disable-with={gettext("Checking...")}
          class="mb-2 px-4 py-2 rounded-xl bg-zinc-900 dark:bg-zinc-100 text-white dark:text-zinc-900 text-sm font-medium hover:bg-zinc-700 dark:hover:bg-zinc-300 transition disabled:opacity-50 flex items-center justify-center gap-1.5"
        >
          <.icon name="hero-no-symbol" class="w-4 h-4" />
          {gettext("Leave out")}
        </button>
      </.form>

      <ul
        id="exclusion-rows"
        class="divide-y divide-zinc-200/60 dark:divide-zinc-800 border-t border-zinc-200/60 dark:border-zinc-800"
      >
        <li :if={@exclusions == []} id="no-exclusions" class="py-4 text-xs text-zinc-500 text-center">
          {gettext(
            "Nothing is left out. Use \"Leave out\" on a document below, or enter a Drive URL above."
          )}
        </li>
        <li
          :for={ex <- @exclusions}
          id={"exclusion-#{ex.id}"}
          class="py-3 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs"
        >
          <.icon
            name={if(ex.kind == "folder", do: "hero-folder", else: "hero-document")}
            class="w-4 h-4 text-zinc-400 shrink-0"
          />
          <div class="min-w-0 flex-1">
            <p class="font-medium text-zinc-900 dark:text-zinc-100 break-all">
              {ex.name || ex.drive_id}
              <span
                :if={ex.kind == "folder"}
                class="ml-1 text-[10px] font-normal text-zinc-500"
              >
                {gettext("(folder: everything below it)")}
              </span>
            </p>
            <p :if={ex.path} class="text-[11px] text-zinc-500 break-all">{ex.path}</p>
          </div>
          <span class="text-[11px] text-zinc-500">
            <%= if ex.source == "system" do %>
              <span class="px-2 py-0.5 rounded-full bg-indigo-50 text-indigo-700 dark:bg-indigo-950/50 dark:text-indigo-300 text-[10px] font-medium">
                {gettext("Written by AskDrive")}
              </span>
            <% else %>
              {AskDrive.Clock.format(ex.inserted_at, "%Y-%m-%d %H:%M")} · {ex.excluded_by ||
                gettext("an administrator")}
            <% end %>
          </span>
          <button
            :if={ex.source == "admin"}
            type="button"
            id={"remove-exclusion-#{ex.id}"}
            phx-click="remove_exclusion"
            phx-value-id={ex.id}
            disabled={@busy?}
            data-confirm={
              if(ex.kind == "folder",
                do:
                  gettext("Bring this folder back? Its documents are read again in the next batch."),
                else: gettext("Bring this file back? It is read again in the next batch.")
              )
            }
            class="px-2.5 py-1 rounded-lg border border-zinc-200 dark:border-zinc-700 text-zinc-600 dark:text-zinc-300 hover:bg-emerald-50 hover:border-emerald-200 hover:text-emerald-700 dark:hover:bg-emerald-950/30 transition disabled:opacity-50 inline-flex items-center gap-1"
          >
            <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
            {gettext("Bring back")}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :doc, :map, required: true
  attr :excluded?, :boolean, default: false
  attr :busy?, :boolean, default: false

  @doc "The documents list's per-row menu: leave out this file, or a folder it sits in."
  def row_menu(assigns) do
    assigns = assign(assigns, :folders, Documents.ancestor_folders(assigns.doc))

    ~H"""
    <span :if={@excluded?} class="text-[11px] text-zinc-400">{gettext("Left out")}</span>
    <details
      :if={not @excluded?}
      id={"exclude-menu-#{@doc.id}"}
      class="inline-block text-right"
    >
      <summary class="list-none cursor-pointer px-2 py-1 rounded-lg text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-zinc-800 dark:hover:text-zinc-200 transition inline-flex items-center gap-1 [&::-webkit-details-marker]:hidden">
        <.icon name="hero-no-symbol" class="w-3.5 h-3.5" />
        <span>{gettext("Leave out")}</span>
      </summary>
      <div class="mt-1 w-60 ml-auto p-1 rounded-xl text-left whitespace-normal bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-700 shadow-lg">
        <button
          type="button"
          id={"exclude-file-#{@doc.id}"}
          phx-click="exclude_document"
          phx-value-id={@doc.id}
          disabled={@busy?}
          data-confirm={
            gettext("Leave \"%{name}\" out of the nightly batch? It is removed from the index now.",
              name: @doc.name
            )
          }
          class="w-full text-left px-3 py-2 rounded-lg text-xs text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition disabled:opacity-50 flex items-center gap-2"
        >
          <.icon name="hero-document" class="w-4 h-4 text-zinc-400 shrink-0" />
          {gettext("This file only")}
        </button>
        <button
          :for={folder <- Enum.reverse(@folders)}
          type="button"
          id={"exclude-folder-#{@doc.id}-#{folder.id}"}
          phx-click="exclude_folder"
          phx-value-id={@doc.id}
          phx-value-folder={folder.id}
          disabled={@busy?}
          data-confirm={
            gettext(
              "Leave the folder \"%{name}\" and everything below it out of the nightly batch? Its documents are removed from the index now.",
              name: folder.name
            )
          }
          class="w-full text-left px-3 py-2 rounded-lg text-xs text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition disabled:opacity-50 flex items-center gap-2"
        >
          <.icon name="hero-folder" class="w-4 h-4 text-zinc-400 shrink-0" />
          <span class="break-all">{gettext("Folder \"%{name}\"", name: folder.name)}</span>
        </button>
        <p
          :if={is_nil(@doc.folder_ids)}
          class="px-3 py-2 text-[11px] text-zinc-400 leading-relaxed"
        >
          {gettext("Folders can be chosen here after the next sync, or left out by their URL above.")}
        </p>
      </div>
    </details>
    """
  end
end
