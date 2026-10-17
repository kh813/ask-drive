defmodule AskDriveWeb.UpdatePanel do
  @moduledoc """
  The platform admin screen's 「アップデート」 tab (spec 12.8, F-1501–F-1506): the running and
  latest versions, starting an update (and what to do with a running batch), its progress and
  log, and the nightly check / automatic update settings. Events go to `AskDriveWeb.AdminLive`.
  """
  use AskDriveWeb, :html

  attr :status, :map, required: true
  attr :setting, :map, required: true
  attr :form, :any, required: true
  attr :latest, :any, default: nil
  attr :checking, :boolean, default: false
  attr :notify_test, :any, default: nil

  def update_tab(assigns) do
    assigns =
      assigns
      |> assign(:available, AskDrive.Updates.available_version(assigns.setting))
      |> assign(:active?, assigns.status.phase in [:building, :waiting_batch, :restarting])

    ~H"""
    <div id="update-panel" class="space-y-6">
      <%!-- Versions --%>
      <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
              <.icon name="hero-arrow-path-rounded-square" class="w-5 h-5 text-indigo-600" />
              {gettext("AskDrive updates")}
            </h2>
            <p class="text-xs text-zinc-500 mt-1 leading-relaxed max-w-2xl">
              {gettext(
                "A new version is built in the background while the server and batches keep running, then switched to with a short restart (about 30 seconds). During the restart, open screens show “Updating” and reload automatically when it is done."
              )}
            </p>
          </div>
          <button
            type="button"
            id="check-updates-btn"
            phx-click="check_updates"
            disabled={@checking}
            class="px-3.5 py-2 rounded-xl border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium flex items-center gap-1.5 transition disabled:opacity-50"
          >
            <.icon name="hero-arrow-path" class={["w-4 h-4", @checking && "animate-spin"]} />
            {if @checking, do: gettext("Checking…"), else: gettext("Check now")}
          </button>
        </div>

        <dl class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
          <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
            <dt class="text-zinc-500">{gettext("Running version")}</dt>
            <dd
              id="update-current"
              class="mt-1 font-mono text-base font-semibold text-zinc-900 dark:text-zinc-100"
            >
              v{AskDrive.version()}
            </dd>
          </div>
          <div class={[
            "p-3 rounded-xl border",
            if(@available,
              do: "bg-indigo-50 dark:bg-indigo-950/40 border-indigo-200 dark:border-indigo-900",
              else: "bg-zinc-50 dark:bg-zinc-950 border-zinc-200/60 dark:border-zinc-800"
            )
          ]}>
            <dt class="text-zinc-500">{gettext("Latest")}</dt>
            <dd
              id="update-latest"
              class="mt-1 font-mono text-base font-semibold text-zinc-900 dark:text-zinc-100"
            >
              {if @setting.update_latest_version, do: "v#{@setting.update_latest_version}", else: "—"}
              <span
                :if={@available}
                class="ml-1 align-middle text-[10px] font-sans font-semibold px-1.5 py-0.5 rounded-full bg-indigo-600 text-white"
              >
                {gettext("New version available")}
              </span>
              <span
                :if={@setting.update_latest_version && !@available}
                class="ml-1 align-middle text-[10px] font-sans text-emerald-600 dark:text-emerald-400"
              >
                {gettext("Up to date")}
              </span>
            </dd>
          </div>
          <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
            <dt class="text-zinc-500">{gettext("Last checked")}</dt>
            <dd class="mt-1 text-zinc-700 dark:text-zinc-300">
              {if @setting.update_checked_at,
                do: AskDrive.Clock.format(@setting.update_checked_at, "%Y-%m-%d %H:%M"),
                else: gettext("Not checked yet")}
            </dd>
          </div>
        </dl>

        <%= case @latest do %>
          <% {:error, message} -> %>
            <p id="update-check-error" class="text-xs text-red-600 dark:text-red-400">{message}</p>
          <% {:ok, latest} -> %>
            <details
              :if={latest.notes != ""}
              id="update-notes"
              class="text-xs"
              open={@available != nil}
            >
              <summary class="cursor-pointer text-zinc-600 dark:text-zinc-400 select-none">
                {gettext("Release notes for v%{version}", version: latest.version)}
                <a
                  :if={latest.url}
                  href={latest.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="ml-1 underline text-indigo-600"
                >{gettext("View on GitHub")}</a>
              </summary>
              <pre class="mt-2 p-3 rounded-lg bg-zinc-50 dark:bg-zinc-950 text-[11px] text-zinc-700 dark:text-zinc-300 whitespace-pre-wrap max-h-60 overflow-y-auto">{latest.notes}</pre>
            </details>
          <% _ -> %>
        <% end %>

        <p
          :if={@setting.update_last_result}
          id="update-last-result"
          class="text-xs text-zinc-600 dark:text-zinc-400 flex items-center gap-1.5"
        >
          <.icon name="hero-clock" class="w-3.5 h-3.5 text-zinc-400" />
          {gettext("Last update: %{result}", result: @setting.update_last_result)}
        </p>

        <%!-- Start --%>
        <form
          :if={!@active?}
          id="start-update-form"
          phx-submit="start_update"
          class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3"
        >
          <fieldset class="space-y-1.5 text-xs text-zinc-700 dark:text-zinc-300">
            <legend class="font-medium text-zinc-800 dark:text-zinc-200 mb-1">
              {gettext("If the build finishes while a batch is running")}
            </legend>
            <label class="flex items-start gap-2 cursor-pointer">
              <input type="radio" name="wait" value="boundary" checked class="mt-0.5" />
              <span>
                <strong>{gettext("Pause at a break point, restart, and resume where it left off after the restart")}</strong>{gettext(
                  " (recommended; it stops once the file / chunk being processed is finished)"
                )}
              </span>
            </label>
            <label class="flex items-start gap-2 cursor-pointer">
              <input type="radio" name="wait" value="batch_end" class="mt-0.5" />
              <span>
                {gettext(
                  "Wait until the batch finishes, then restart (during the nightly batch this can take until morning)"
                )}
              </span>
            </label>
          </fieldset>
          <div class="flex flex-wrap items-center gap-3">
            <%!-- only when a newer version is out: nothing to do on the latest one --%>
            <button
              type="submit"
              id="start-update-btn"
              disabled={!@available}
              data-confirm={
                gettext(
                  "Update AskDrive to v%{version}? Once the build is done, it restarts for about 30 seconds.",
                  version: to_string(@available)
                )
              }
              class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm flex items-center gap-1.5 transition disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-indigo-600"
            >
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("Update now")}
            </button>
            <span :if={!@available} id="start-update-hint" class="text-xs text-zinc-500">
              {if @setting.update_latest_version,
                do: gettext("Running the latest version."),
                else: gettext("Check for the latest version with “Check now” to be able to update.")}
            </span>
          </div>
        </form>
      </div>

      <%!-- Progress --%>
      <div
        :if={@status.phase != :idle}
        id="update-progress"
        class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-3"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <span class={[
              "px-2 py-0.5 rounded-full text-[11px] font-semibold",
              phase_class(@status.phase)
            ]}>
              {phase_label(@status.phase)}
            </span>
            <span class="text-xs text-zinc-500">
              v{@status.from} → {if @status.to, do: "v#{@status.to}", else: gettext("latest version")}
              <span :if={@status.by}> · {@status.by}</span>
              <span :if={@status.started_at}>
                · {gettext("started %{time}", time: AskDrive.Clock.format(@status.started_at, "%H:%M"))}
              </span>
            </span>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={@status.phase == :building}
              type="button"
              id="cancel-update-btn"
              phx-click="cancel_update"
              data-confirm={gettext("Cancel the build? (The running server is not affected.)")}
              class="px-3 py-1.5 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs transition"
            >
              {gettext("Abort")}
            </button>
            <button
              :if={@status.phase == :waiting_batch}
              type="button"
              id="restart-now-btn"
              phx-click="restart_now"
              data-confirm={
                gettext(
                  "Restart now without waiting for the batch? The file (or chunk) being processed will be redone."
                )
              }
              class="px-3 py-1.5 rounded-lg bg-amber-600 hover:bg-amber-700 text-white text-xs font-medium transition"
            >
              {gettext("Restart now")}
            </button>
          </div>
        </div>
        <p
          id="update-message"
          class="text-sm text-zinc-800 dark:text-zinc-200 flex items-center gap-2"
        >
          <.icon :if={@active?} name="hero-arrow-path" class="w-4 h-4 animate-spin text-indigo-600" />
          {@status.message}
        </p>
        <pre
          :if={@status.log != []}
          id="update-log"
          phx-hook=".ScrollToEnd"
          class="p-3 rounded-lg bg-zinc-950 text-zinc-200 text-[11px] leading-relaxed max-h-80 overflow-y-auto whitespace-pre-wrap"
        >{Enum.join(@status.log, "\n")}</pre>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToEnd">
          export default {
            mounted() { this.el.scrollTop = this.el.scrollHeight },
            updated() { this.el.scrollTop = this.el.scrollHeight }
          }
        </script>
      </div>

      <%!-- Settings --%>
      <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
        <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
          <.icon name="hero-moon" class="w-5 h-5 text-indigo-600" /> {gettext("Nightly updates")}
        </h2>
        <div id="update-settings" class="space-y-2">
          <AskDriveWeb.FeatureToggle.toggle
            id="toggle-update-check"
            feature="update_check"
            on={@setting.update_check_enabled == true}
            label={gettext("Check for a new version every night")}
            hint={
              gettext(
                "At the start of the night window. When one is found, it is shown on this screen and in the admin screen header."
              )
            }
          />
          <AskDriveWeb.FeatureToggle.toggle
            id="toggle-update-auto-apply"
            feature="update_auto_apply"
            on={@setting.update_auto_apply == true}
            label={gettext("Update automatically when a new version is found")}
            hint={gettext("Runs before the nightly batch; the batch starts after the restart.")}
            confirm_on={
              gettext(
                "On a night when a new version is found, AskDrive will update and restart automatically. Continue?"
              )
            }
          />
          <p class="text-[11px] text-zinc-500 leading-relaxed">
            {gettext(
              "Even with automatic updates, if the build fails the running version keeps running. Switching over automatically by restarting requires AskDrive to be a resident service ("
            )}<code class="font-mono">./app.sh service install</code>{gettext(
              ") registered on the server."
            )}
          </p>
        </div>
      </div>

      <%!-- Notices to Google Chat (F-1507) --%>
      <div
        id="update-notify"
        class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
      >
        <div>
          <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
            <.icon name="hero-bell-alert" class="w-5 h-5 text-indigo-600" /> {gettext(
              "Notifications (Google Chat)"
            )}
          </h2>
          <p class="text-xs text-zinc-500 mt-1 leading-relaxed max-w-2xl">
            {gettext(
              "Posts to a Google Chat space when an update starts and when the new version has started and is running normally (automatic and manual alike). If only the start notice arrives and no completion notice follows, AskDrive may have failed to start after the restart. A failed build, or starting on the old version, is also notified."
            )}
          </p>
        </div>
        <ol class="list-decimal pl-5 text-[11px] text-zinc-600 dark:text-zinc-400 space-y-0.5">
          <li>
            {gettext(
              "In Google Chat, open the space to notify, then space name → “Apps & integrations” → “Add webhooks”"
            )}
          </li>
          <li>{gettext("Enter a name (e.g. AskDrive), save, and copy the URL shown")}</li>
          <li>{gettext("Paste it below, save, and check that “Send test” arrives")}</li>
        </ol>
        <.form
          for={@form}
          id="notify-settings-form"
          phx-submit="save_notify_settings"
          class="space-y-3"
        >
          <.input
            field={@form[:google_chat_webhook_url]}
            type="password"
            value=""
            autocomplete="off"
            label={
              if AskDrive.Notify.GoogleChat.configured?(@setting),
                do: gettext("Webhook URL (set; enter only to change it)"),
                else: gettext("Webhook URL (not set)")
            }
            placeholder="https://chat.googleapis.com/v1/spaces/.../messages?key=...&token=..."
          />
          <div class="flex flex-wrap items-center justify-end gap-2">
            <button
              :if={AskDrive.Notify.GoogleChat.configured?(@setting)}
              type="button"
              id="clear-google-chat-btn"
              phx-click="clear_google_chat"
              data-confirm={
                gettext("Delete the Google Chat webhook URL? (Notifications will stop arriving.)")
              }
              class="px-3.5 py-2 rounded-xl border border-zinc-200 dark:border-zinc-700 hover:bg-red-50 hover:text-red-700 dark:hover:bg-red-950/40 text-xs transition"
            >
              {gettext("Delete")}
            </button>
            <button
              :if={AskDrive.Notify.GoogleChat.configured?(@setting)}
              type="button"
              id="test-google-chat-btn"
              phx-click="test_google_chat"
              phx-disable-with={gettext("Sending…")}
              class="px-3.5 py-2 rounded-xl border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium transition"
            >
              {gettext("Send test")}
            </button>
            <button
              type="submit"
              id="save-notify-settings-btn"
              class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
            >
              {gettext("Save")}
            </button>
          </div>
        </.form>
        <%= case @notify_test do %>
          <% :ok -> %>
            <p id="google-chat-test-result" class="text-xs text-emerald-600 dark:text-emerald-400">
              {gettext("Test notice sent. Check that it arrived in the Google Chat space.")}
            </p>
          <% {:error, message} -> %>
            <p id="google-chat-test-result" class="text-xs text-red-600 dark:text-red-400">
              {message}
            </p>
          <% _ -> %>
        <% end %>
      </div>
    </div>
    """
  end

  defp phase_label(:building), do: gettext("Building")
  defp phase_label(:waiting_batch), do: gettext("Waiting to restart")
  defp phase_label(:restarting), do: gettext("Restarting")
  defp phase_label(:built), do: gettext("Build done (restart manually)")
  defp phase_label(:failed), do: gettext("Failed / cancelled")
  defp phase_label(_), do: ""

  defp phase_class(:failed), do: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"

  defp phase_class(:built),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

  defp phase_class(_),
    do: "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300 animate-pulse"
end
