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
              AskDrive のアップデート
            </h2>
            <p class="text-xs text-zinc-500 mt-1 leading-relaxed max-w-2xl">
              新しいバージョンは、サーバーとバッチを動かしたまま裏でビルドし、終わったら短い再起動（30 秒ほど）で切り替えます。再起動のあいだ、開いている画面には「アップデート中」と表示され、終わると自動で再読み込みします。
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
            {if @checking, do: "確認しています…", else: "今すぐ確認"}
          </button>
        </div>

        <dl class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
          <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
            <dt class="text-zinc-500">稼働中</dt>
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
            <dt class="text-zinc-500">最新</dt>
            <dd
              id="update-latest"
              class="mt-1 font-mono text-base font-semibold text-zinc-900 dark:text-zinc-100"
            >
              {if @setting.update_latest_version, do: "v#{@setting.update_latest_version}", else: "—"}
              <span
                :if={@available}
                class="ml-1 align-middle text-[10px] font-sans font-semibold px-1.5 py-0.5 rounded-full bg-indigo-600 text-white"
              >
                新しいバージョンがあります
              </span>
              <span
                :if={@setting.update_latest_version && !@available}
                class="ml-1 align-middle text-[10px] font-sans text-emerald-600 dark:text-emerald-400"
              >
                最新です
              </span>
            </dd>
          </div>
          <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
            <dt class="text-zinc-500">最後の確認</dt>
            <dd class="mt-1 text-zinc-700 dark:text-zinc-300">
              {if @setting.update_checked_at,
                do: AskDrive.Clock.format(@setting.update_checked_at, "%Y-%m-%d %H:%M"),
                else: "まだ確認していません"}
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
                v{latest.version} のリリースノート
                <a
                  :if={latest.url}
                  href={latest.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="ml-1 underline text-indigo-600"
                >GitHub で見る</a>
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
          前回のアップデート: {@setting.update_last_result}
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
              バッチの実行中にビルドが終わったら
            </legend>
            <label class="flex items-start gap-2 cursor-pointer">
              <input type="radio" name="wait" value="boundary" checked class="mt-0.5" />
              <span>
                <strong>区切りで一時停止して再起動し、再起動後に続きから再開する</strong>（推奨。止まるのは処理中のファイル／チャンクが終わった時点）
              </span>
            </label>
            <label class="flex items-start gap-2 cursor-pointer">
              <input type="radio" name="wait" value="batch_end" class="mt-0.5" />
              <span>バッチが終わるまで待ってから再起動する（夜間バッチ中だと朝までかかることがあります）</span>
            </label>
          </fieldset>
          <button
            type="submit"
            id="start-update-btn"
            data-confirm={"AskDrive を#{if @available, do: " v#{@available} に", else: "最新版に"}アップデートしますか？ビルドが終わると、30 秒ほど再起動します。"}
            class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm flex items-center gap-1.5 transition"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
            {if @available, do: "v#{@available} にアップデート", else: "最新版でアップデート（再ビルド）"}
          </button>
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
              v{@status.from} → {if @status.to, do: "v#{@status.to}", else: "最新版"}
              <span :if={@status.by}>・{@status.by}</span>
              <span :if={@status.started_at}>
                ・{AskDrive.Clock.format(@status.started_at, "%H:%M")} 開始
              </span>
            </span>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={@status.phase == :building}
              type="button"
              id="cancel-update-btn"
              phx-click="cancel_update"
              data-confirm="ビルドを中止しますか？（稼働中のサーバーは変わりません）"
              class="px-3 py-1.5 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs transition"
            >
              中止
            </button>
            <button
              :if={@status.phase == :waiting_batch}
              type="button"
              id="restart-now-btn"
              phx-click="restart_now"
              data-confirm="バッチを待たずに今すぐ再起動しますか？処理中のファイル（またはチャンク）はやり直しになります。"
              class="px-3 py-1.5 rounded-lg bg-amber-600 hover:bg-amber-700 text-white text-xs font-medium transition"
            >
              今すぐ再起動
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
          <.icon name="hero-moon" class="w-5 h-5 text-indigo-600" /> 夜間のアップデート
        </h2>
        <.form
          for={@form}
          id="update-settings-form"
          phx-submit="save_update_settings"
          class="space-y-3"
        >
          <.input
            field={@form[:update_check_enabled]}
            type="checkbox"
            label="毎晩、新しいバージョンを確認する（夜間枠の開始時。見つかるとこの画面と管理画面の見出しに表示）"
          />
          <.input
            field={@form[:update_auto_apply]}
            type="checkbox"
            label="新しいバージョンが見つかったら自動でアップデートする（夜間バッチより先に行い、バッチは再起動後に始まります）"
          />
          <p class="text-[11px] text-zinc-500 leading-relaxed">
            自動アップデートでも、ビルドに失敗した場合は稼働中のバージョンのまま動き続けます。再起動による自動の切り替えには、AskDrive が常駐サービス（<code class="font-mono">./app.sh service install</code>）として登録されている必要があります。
          </p>
          <div class="flex justify-end">
            <button
              type="submit"
              id="save-update-settings-btn"
              class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
            >
              保存
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp phase_label(:building), do: "ビルド中"
  defp phase_label(:waiting_batch), do: "再起動待ち"
  defp phase_label(:restarting), do: "再起動中"
  defp phase_label(:built), do: "ビルド完了（手動で再起動）"
  defp phase_label(:failed), do: "失敗・中止"
  defp phase_label(_), do: ""

  defp phase_class(:failed), do: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"

  defp phase_class(:built),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

  defp phase_class(_),
    do: "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300 animate-pulse"
end
