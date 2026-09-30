defmodule AskDriveWeb.SetupLive do
  @moduledoc """
  First-access setup (spec 6.12): setup code, administrator password, the organization's
  Google Workspace domain and the first app's name. See `AskDrive.Setup`.
  """
  use AskDriveWeb, :live_view

  alias AskDrive.Setup

  @impl true
  def mount(_params, _session, socket) do
    if Setup.required?() do
      {:ok,
       socket
       |> assign(:page_title, "AskDrive 初回セットアップ")
       |> assign(:errors, %{})
       |> assign(:values, %{"app_name" => AskDrive.Apps.primary().name})}
    else
      {:ok, push_navigate(socket, to: "/")}
    end
  end

  @impl true
  def handle_event("setup", params, socket) do
    case Setup.complete(params) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "初回セットアップが完了しました。次に、窓口の Google Drive と AI を設定してください。")
         |> redirect(to: "/admin?tab=apps")}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:errors, errors)
         |> assign(:values, Map.take(params, ["domain", "app_name", "admin_emails"]))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      admin_elevated?={false}
      admin_elevation_expires_at={nil}
    >
      <div class="max-w-xl mx-auto space-y-6">
        <div>
          <h1 class="font-bold text-2xl text-zinc-900 dark:text-zinc-100">AskDrive 初回セットアップ</h1>
          <p class="text-sm text-zinc-500 mt-1 leading-relaxed">
            最初に、管理者パスワードと組織の情報を設定します。この画面はセットアップが終わるまで表示されます。
          </p>
        </div>

        <form
          id="setup-form"
          phx-submit="setup"
          class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-5"
        >
          <.setup_field
            name="code"
            label="1. セットアップコード"
            errors={@errors}
            placeholder="XXXX-XXXX-XXXX"
            autocomplete="off"
          >
            サーバーを操作できる人だけが最初の管理者になれるよう、サーバー上で確認できるコードを入力します。
            <code class="font-mono">./app.sh status</code>
            の表示、またはサーバーの起動ログ（「セットアップコード」）で確認できます。
          </.setup_field>

          <.setup_field
            name="password"
            type="password"
            label="2. 管理者パスワード"
            errors={@errors}
            autocomplete="new-password"
          >
            管理画面に入る（管理者に昇格する）ときに入力します。{AskDrive.Accounts.AdminAccess.min_password_length()} 文字以上。
          </.setup_field>
          <.setup_field
            name="password_confirmation"
            type="password"
            label="管理者パスワード（確認）"
            errors={@errors}
            autocomplete="new-password"
          />

          <.setup_field
            name="domain"
            label="3. 組織の Google Workspace ドメイン"
            errors={@errors}
            value={@values["domain"]}
            placeholder="company.com"
          >
            Google ログイン（SSO）と Google Drive の連携で、このドメインのアカウントだけを受け付けます。
          </.setup_field>

          <.setup_field
            name="app_name"
            label="4. 最初の窓口の名前"
            errors={@errors}
            value={@values["app_name"]}
          >
            チャット画面に「AskDrive for（この名前）」と表示されます。あとから変更でき、窓口は全体管理で追加できます。
          </.setup_field>

          <.setup_field
            name="admin_emails"
            label="5. 最初の窓口の担当者（窓口管理者）のメールアドレス"
            errors={@errors}
            value={@values["admin_emails"]}
            placeholder="name@company.com"
          >
            この窓口の設定（Google Drive・API キー等）を行う人です（複数ならカンマ区切り）。窓口の管理画面に入れるのは担当者だけで、全体管理者は入れません。担当者はあとから追加・引き継ぎできます。
          </.setup_field>

          <button
            type="submit"
            id="setup-submit"
            class="w-full px-4 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-sm shadow-sm"
          >
            セットアップを完了する
          </button>
          <p class="text-[11px] text-zinc-500">
            Google ログインの OAuth クライアント ID / シークレットは、あとで全体管理の「全体設定」で設定できます。
          </p>
        </form>
      </div>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :errors, :map, required: true
  attr :type, :string, default: "text"
  attr :value, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :autocomplete, :string, default: nil
  slot :inner_block

  defp setup_field(assigns) do
    ~H"""
    <label class="block space-y-1">
      <span class="block text-sm font-medium text-zinc-800 dark:text-zinc-200">{@label}</span>
      <input
        type={@type}
        name={@name}
        id={"setup-" <> @name}
        value={@value}
        placeholder={@placeholder}
        autocomplete={@autocomplete}
        class={[
          "w-full px-3 py-2 rounded-lg border bg-white dark:bg-zinc-950 text-sm",
          if(@errors[String.to_atom(@name)],
            do: "border-red-400",
            else: "border-zinc-300 dark:border-zinc-700"
          )
        ]}
      />
      <span :if={msg = @errors[String.to_atom(@name)]} class="block text-xs text-red-600">{msg}</span>
      <span :if={@inner_block != []} class="block text-xs text-zinc-500 leading-relaxed">
        {render_slot(@inner_block)}
      </span>
    </label>
    """
  end
end
