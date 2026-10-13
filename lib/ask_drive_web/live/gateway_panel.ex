defmodule AskDriveWeb.GatewayPanel do
  @moduledoc """
  The platform admin screen's API gateway section, inside the HTTPS card (spec F-1014): the
  secret header's value, the public URL, the ranges that may still connect directly, and
  whether this very connection came through the gateway. Events go to
  `AskDriveWeb.AdminLive` (`save_gateway`).
  """
  use AskDriveWeb, :html

  attr :gw, :map, required: true, doc: "`AskDrive.Gateway.settings/0`, refreshed on each change"
  attr :peer_ip, :string, default: nil
  attr :via_gateway, :boolean, default: false

  def gateway_section(assigns) do
    assigns = assign(assigns, :on?, assigns.gw.enabled and assigns.gw.secret != nil)

    ~H"""
    <div id="gateway-settings" class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3">
      <div class="flex flex-wrap items-center gap-2">
        <h3 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200 flex items-center gap-2">
          <.icon name="hero-building-office-2" class="w-4 h-4 text-indigo-600" />
          API ゲートウェイ（Google ログインの入口）
        </h3>
        <span
          id="gateway-state"
          class={[
            "text-[11px] font-medium px-2 py-0.5 rounded-full",
            if(@on?,
              do: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-200",
              else: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
            )
          ]}
        >
          {if @on?, do: "有効（ゲートウェイ経由のみ）", else: "無効"}
        </span>
      </div>
      <p class="text-xs text-zinc-500 leading-relaxed">
        さくらのクラウドの API ゲートウェイなどで Google Workspace のログインを通った人だけが AskDrive に届くようにします。ゲートウェイは転送するすべてのリクエストに秘密のヘッダー（<code class="font-mono">X-Apigw-Secret</code>）を付けます。ここに同じ値を設定すると、ヘッダーのない直接アクセスは 403 で拒否します（ログイン画面も画面の更新用の接続も含みます）。ゲートウェイからのリクエストは、利用者の IP（X-Forwarded-For）を信頼し、リンク・リダイレクト・Google ログインのリダイレクト URI を下の「公開 URL」で組み立てます。
      </p>
      <p class="text-xs text-zinc-600 dark:text-zinc-400">
        この画面の接続:
        <span id="gateway-this-connection" class="font-medium">
          {if @via_gateway,
            do: "ゲートウェイ経由（秘密のヘッダーあり）",
            else: "直接（#{@peer_ip || "不明"}）"}
        </span>
      </p>

      <AskDriveWeb.FeatureToggle.toggle
        id="toggle-gateway"
        feature="gateway"
        on={@on?}
        label="API ゲートウェイの確認"
        hint="秘密のヘッダーの値と公開 URL を保存してから有効にできます。有効にした時点から、ヘッダーのない直接アクセスを拒否します"
        confirm_on="API ゲートウェイの確認を有効にします。ゲートウェイを通らない接続（サーバー自身と許可した IP を除く）は、すぐに拒否されます。続行しますか？"
      />

      <form id="gateway-form" phx-submit="save_gateway" class="space-y-3">
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs">
          <label class="space-y-1">
            <span class="block font-medium">
              秘密のヘッダーの値（{if @gw.secret, do: "設定済み。変更するときだけ入力", else: "未設定"}・16 文字以上）
            </span>
            <input
              type="password"
              name="gateway[secret]"
              value=""
              autocomplete="off"
              class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
            />
          </label>
          <label class="space-y-1">
            <span class="block font-medium">公開 URL（利用者が開く URL）</span>
            <input
              type="url"
              name="gateway[public_url]"
              value={@gw.public_url}
              placeholder="例: https://app.example.com"
              class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
            />
          </label>
          <label class="space-y-1 sm:col-span-2">
            <span class="block font-medium">
              ゲートウェイを通さずに直接アクセスを許可する IP（任意・カンマ区切り、範囲は 192.168.0.0/16 の形。空欄なら許可しない）
            </span>
            <input
              type="text"
              name="gateway[direct_ranges]"
              value={Enum.join(@gw.direct_ranges, ", ")}
              placeholder="例: 192.168.0.0/16（移行期間中に社内 LAN から直接使う場合）"
              class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
            />
          </label>
        </div>
        <p class="text-[11px] text-zinc-400 leading-relaxed">
          「保存」は値を保存するだけで、確認の有効・無効は上のスイッチで切り替えます。有効にできるのは、この画面がゲートウェイ経由（同じ秘密の値）・サーバー自身（localhost）・直接アクセスを許可する IP のいずれかから開かれているときだけです（自分を締め出さないため）。サーバー自身からは常に直接アクセスできます。締め出された場合はサーバー上で
          <code class="font-mono">./app.sh network gateway-off</code>
          を実行してください（再起動なしで反映）。秘密の値はメールに書かず、安全な方法で受け取ってください。
        </p>
        <div class="flex justify-end">
          <button
            type="submit"
            id="save-gateway-btn"
            class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
          >
            保存
          </button>
        </div>
      </form>
    </div>
    """
  end
end
