defmodule AskDriveWeb.AcmePanel do
  @moduledoc """
  The platform admin screen's Let's Encrypt section, inside the HTTPS card (spec F-1009 –
  F-1012): the settings (host name, Value-Domain zone and API key, contact, staging), the
  last result and the next renewal, a DNS connection test, 「今すぐ取得」, and the steps of
  the run in progress. Events go to `AskDriveWeb.AdminLive`.
  """
  use AskDriveWeb, :html

  alias AskDrive.ACME.Renewal

  attr :setting, :map, required: true
  attr :form, :any, required: true
  attr :status, :map, default: nil
  attr :dns_test, :any, default: nil

  def acme_section(assigns) do
    assigns =
      assigns
      |> assign(:running?, match?(%{running?: true}, assigns.status))
      |> assign(:configured?, Renewal.configured?(assigns.setting))
      |> assign(:renew_after, Renewal.renew_after())

    ~H"""
    <div id="acme-settings" class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3">
      <div>
        <h3 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200 flex items-center gap-2">
          <.icon name="hero-shield-check" class="w-4 h-4 text-emerald-600" />
          Let's Encrypt（証明書の自動取得・自動更新）
        </h3>
        <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
          ブラウザや API ゲートウェイが信頼する証明書を Let's Encrypt から無料で取得し、期限が近づくと自動で更新します。所有の確認は DNS の TXT レコードで行う（DNS-01）ため、このサーバーは LAN 内のままで構いません。TXT レコードはバリュードメインの DNS API で追加し、確認が済んだらすぐ削除します。更新は、残りの有効期間が 3 分の 1（90 日の証明書なら 30 日）を切った夜に、夜間バッチの時間帯に 1 回試し、失敗しても翌晩以降に再び試します。結果は Google Chat に通知します（アップデートの通知先を設定している場合）。
        </p>
      </div>

      <div id="acme-state" class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
        <div>
          <span class="text-zinc-400 block">状態</span>
          <span class={[
            "font-medium",
            cond do
              @running? -> "text-indigo-700 dark:text-indigo-300"
              @configured? -> "text-emerald-700 dark:text-emerald-300"
              true -> "text-zinc-500"
            end
          ]}>
            {cond do
              @running? -> "取得中…"
              @configured? -> "有効"
              @setting.acme_enabled -> "設定が足りません"
              true -> "無効"
            end}
          </span>
        </div>
        <div>
          <span class="text-zinc-400 block">前回の実行</span>
          <span class="font-mono">{AskDrive.Clock.format(@setting.acme_checked_at, "%Y-%m-%d %H:%M")}</span>
        </div>
        <div>
          <span class="text-zinc-400 block">次の更新</span>
          <span class="font-mono">
            {if @renew_after,
              do: AskDrive.Clock.format(@renew_after, "%Y-%m-%d") <> " 以降の夜",
              else: "—（Let's Encrypt の証明書の取得後に表示）"}
          </span>
        </div>
      </div>

      <p
        :if={@setting.acme_last_result && not @running?}
        id="acme-last-result"
        class={[
          "text-xs rounded-lg border px-3 py-2 break-all",
          if(@setting.acme_last_ok,
            do:
              "border-emerald-200 bg-emerald-50 text-emerald-800 dark:bg-emerald-950/40 dark:border-emerald-900 dark:text-emerald-200",
            else:
              "border-red-200 bg-red-50 text-red-700 dark:bg-red-950/40 dark:border-red-900 dark:text-red-300"
          )
        ]}
      >
        {if @setting.acme_last_ok, do: "成功: ", else: "失敗: "}{@setting.acme_last_result}
      </p>

      <div
        :if={@status && @status.log != []}
        id="acme-log"
        class="rounded-lg bg-zinc-950 text-zinc-100 font-mono text-[11px] leading-relaxed px-3 py-2 max-h-48 overflow-y-auto"
      >
        <p :for={line <- Enum.reverse(@status.log)} class="whitespace-pre-wrap break-all">{line}</p>
      </div>

      <.form for={@form} id="acme-form" phx-submit="save_acme" class="space-y-3">
        <.input
          field={@form[:acme_enabled]}
          type="checkbox"
          label="Let's Encrypt の証明書を自動で取得・更新する"
        />
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <.input
            field={@form[:acme_hostname]}
            type="text"
            label="証明書のホスト名"
            placeholder="例: ask.example.com"
          />
          <.input
            field={@form[:acme_dns_zone]}
            type="text"
            label="バリュードメインで管理しているドメイン"
            placeholder="例: example.com"
          />
          <.input
            field={@form[:valuedomain_api_key]}
            type="password"
            value=""
            autocomplete="off"
            label={"バリュードメインの API キー（#{if present?(@setting.valuedomain_api_key), do: "設定済み。変更するときだけ入力", else: "未設定"}）"}
          />
          <.input
            field={@form[:acme_email]}
            type="email"
            label="連絡先メールアドレス（任意）"
            placeholder="期限切れの警告などが Let's Encrypt から届きます"
          />
        </div>
        <.input
          field={@form[:acme_staging]}
          type="checkbox"
          label="テスト用（staging）の証明書を取得する（ブラウザでは警告が出ます。設定の確認用）"
        />
        <p class="text-[11px] text-zinc-500 leading-relaxed">
          API キーはバリュードメインの「API」設定で発行し、暗号化して保存します。バリュードメインの DNS API はドメインのレコードをまとめて書き換える方式のため、変更の前に毎回レコード全体をサーバーの
          <code class="font-mono">ssl/acme/dns_backup/</code>
          に保存し、変更後に読み直して TXT レコード以外が変わっていないことを確かめます。初めて使うときは「テスト用」で取得できることを確かめてから、本番の証明書に切り替えてください（本番には失敗回数の制限があります）。
        </p>
        <div class="flex flex-wrap items-center gap-2">
          <button
            type="submit"
            id="save-acme-btn"
            class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium transition"
          >
            保存
          </button>
          <button
            type="button"
            id="test-acme-dns-btn"
            phx-click="test_acme_dns"
            disabled={
              not present?(@setting.valuedomain_api_key) or not present?(@setting.acme_dns_zone)
            }
            class="px-4 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium transition disabled:opacity-40 disabled:cursor-not-allowed"
          >
            DNS 接続テスト（変更しません）
          </button>
          <button
            type="button"
            id="run-acme-btn"
            phx-click="run_acme"
            disabled={not @configured? or @running?}
            data-confirm="Let's Encrypt から証明書を取得し、HTTPS を再起動して適用します。DNS に一時的な TXT レコードを追加し、確認後に削除します。続行しますか？"
            class="px-4 py-2 rounded-lg border border-emerald-300 text-emerald-800 dark:text-emerald-200 dark:border-emerald-800 hover:bg-emerald-50 dark:hover:bg-emerald-950/40 text-xs font-medium transition disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {if @running?, do: "取得中…", else: "今すぐ取得"}
          </button>
        </div>
      </.form>

      <%= case @dns_test do %>
        <% :running -> %>
          <p id="acme-dns-test" class="text-xs text-zinc-500">バリュードメインに接続しています…</p>
        <% {:ok, count} -> %>
          <p id="acme-dns-test" class="text-xs text-emerald-700 dark:text-emerald-300">
            接続できました（{@setting.acme_dns_zone} のレコード {count} 件を確認。何も変更していません）。
          </p>
        <% {:error, message} -> %>
          <p id="acme-dns-test" class="text-xs text-red-600">{message}</p>
        <% _ -> %>
      <% end %>
    </div>
    """
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
