defmodule AskDriveWeb.AdminLive do
  @moduledoc """
  Admin Dashboard LiveView for AskDrive.
  Provides:
  - Batch status (latest run, phase breakdown, deadline truncation status)
  - Coverage statistics (total chunks, active QAs, stale QAs, unindexed chunks)
  - Unanswered questions and recently resolved questions
  - Synced documents list with statuses and Drive links
  - Provider status and manual batch trigger
  - Settings management (LLM providers and credentials, batch hours, thresholds, models)
  - User management (elevation eligibility and deactivation) and the elevation audit log

  Every action here requires an elevated session; the router and `AskDriveWeb.UserAuth`
  enforce that before this module is reached (spec 6.9 F-911).
  """
  use AskDriveWeb, :live_view
  require Logger
  import Ecto.Query, warn: false

  alias AskDrive.Accounts.{AdminAccess, AdminElevationLog}
  alias AskDrive.Batch.{ItemLog, Scheduler}
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.Drive.{Client, ServiceAccount}
  alias AskDrive.LLM
  alias AskDrive.QA.QAPair
  alias AskDrive.{Accounts, Documents, HealthCheck, QA, Repo, Settings, Vector}
  alias AskDrive.Runtime.Mode

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Refresh status periodically
      :timer.send_interval(5000, self(), :tick)
    end

    setting = Settings.get_setting!()
    form = to_form(Settings.change_setting(setting))

    {:ok,
     socket
     |> assign(:current_tab, "overview")
     |> assign(:setting, setting)
     |> assign(:form, form)
     |> assign(:trigger_batch_loading, false)
     |> assign(:connection_test, %{})
     |> assign(:service_account_test, nil)
     |> assign(:password_form, to_form(%{}, as: :admin_password))
     |> load_dashboard_data()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "overview"
    {:noreply, assign(socket, :current_tab, tab)}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, load_dashboard_data(socket)}
  end

  @impl true
  def handle_event("select_run", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_run_id, String.to_integer(id)) |> load_dashboard_data()}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin?tab=#{tab}")}
  end

  @impl true
  def handle_event("trigger_batch", params, socket) do
    ingest_only? = params["kind"] == "ingest_only"

    if Scheduler.running?() do
      {:noreply, put_flash(socket, :error, "バッチが実行中です。終了してから実行してください。")}
    else
      Logger.info("AdminLive: Triggering manual batch run (ingest_only: #{ingest_only?})...")
      Task.start(fn -> Scheduler.run_batch(ingest_only: ingest_only?) end)

      message =
        if ingest_only?,
          do: "取り込みのみのバッチを開始しました（QA 生成は行いません）。",
          else: "バッチ（QA 生成あり）の実行を開始しました。"

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> load_dashboard_data()}
    end
  end

  @impl true
  def handle_event("save_settings", %{"setting" => setting_params}, socket) do
    # `vec0` fixes the vector width at CREATE time, so a new embedding model or dimension
    # means dropping and rebuilding the index before anything can be re-embedded (F-809).
    reindex? = Settings.reindex_required?(socket.assigns.setting, setting_params)

    case Settings.update_setting(socket.assigns.setting, setting_params) do
      {:ok, updated} ->
        message =
          if reindex? do
            case Vector.rebuild_index(updated.embedding_dim) do
              {:ok, _dim} ->
                "設定を保存し、ベクトルインデックスを再構築しました。次回の夜間バッチで全チャンクを再ベクトル化します。"

              {:error, reason} ->
                Logger.error("Vector index rebuild failed: #{inspect(reason)}")
                "設定は保存しましたが、ベクトルインデックスの再構築に失敗しました。ログを確認してください。"
            end
          else
            "設定を保存しました。"
          end

        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign(:form, to_form(Settings.change_setting(updated)))
         |> put_flash(:info, message)
         |> load_dashboard_data()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(:error, "設定の保存に失敗しました。入力内容を確認してください。")}
    end
  end

  @impl true
  def handle_event("test_connection", %{"role" => role}, socket) do
    role_atom = if role == "embedding", do: :embedding, else: :generation
    result = LLM.connection_test(role_atom, socket.assigns.setting)

    {:noreply,
     assign(socket, :connection_test, Map.put(socket.assigns.connection_test, role_atom, result))}
  end

  @impl true
  def handle_event("set_drive_auth_mode", %{"mode" => mode}, socket) do
    case Settings.update_setting(socket.assigns.setting, %{drive_auth_mode: mode}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign(:form, to_form(Settings.change_setting(updated)))
         |> assign(:service_account_test, nil)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Drive 認証方式を切り替えられませんでした。")}
    end
  end

  @impl true
  def handle_event("save_service_account", %{"setting" => params}, socket) do
    json = String.trim(params["drive_service_account_json"] || "")

    # The key field always renders empty (it is a secret), so a blank submit means "keep the
    # stored key" — that lets the delegation user be changed without re-pasting the key.
    attrs =
      %{
        drive_auth_mode: "service_account",
        drive_impersonate_email: params["drive_impersonate_email"]
      }
      |> then(&if(json == "", do: &1, else: Map.put(&1, :drive_service_account_json, json)))

    case Settings.update_setting(socket.assigns.setting, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign(:form, to_form(Settings.change_setting(updated)))
         |> assign(:service_account_test, nil)
         |> put_flash(:info, "サービスアカウントの認証情報を保存しました。")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(:error, "保存に失敗しました。JSON キーの内容を確認してください。")}
    end
  end

  @impl true
  def handle_event("test_service_account", _params, socket) do
    result =
      case socket.assigns.setting.drive_service_account_json do
        json when is_binary(json) and json != "" ->
          setting = socket.assigns.setting

          case ServiceAccount.fetch_access_token(json, setting.drive_impersonate_email) do
            {:ok, %{access_token: _}} ->
              check_drive_folder(setting)

            {:error, reason} ->
              {:error, "#{reason}"}
          end

        _ ->
          {:error, "先に JSON キーを保存してください。"}
      end

    {:noreply, assign(socket, :service_account_test, result)}
  end

  @impl true
  def handle_event("disconnect_service_account", _params, socket) do
    Accounts.disconnect_service_account()

    {:noreply,
     socket
     |> assign(:setting, Settings.get_setting!())
     |> assign(:service_account_test, nil)
     |> put_flash(:info, "サービスアカウントの認証情報を削除しました。")
     |> load_dashboard_data()}
  end

  @impl true
  def handle_event("set_admin_eligible", %{"id" => id, "eligible" => eligible}, socket) do
    socket.assigns.current_user
    |> Accounts.set_admin_eligible(Accounts.get_user(id), eligible == "true")
    |> handle_user_change(socket)
  end

  @impl true
  def handle_event("change_admin_password", %{"admin_password" => params}, socket) do
    %{"current" => current, "new" => new_password, "confirmation" => confirmation} =
      Map.merge(%{"current" => "", "new" => "", "confirmation" => ""}, params)

    context = %{ip_address: nil, user_agent: nil}

    result =
      if new_password != confirmation do
        {:error, :mismatch}
      else
        AdminAccess.change_password(socket.assigns.current_user, current, new_password, context)
      end

    case result do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> put_flash(:info, "管理者パスワードを変更しました。")
         |> load_dashboard_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, password_error_message(reason))}
    end
  end

  @impl true
  def handle_event("set_user_status", %{"id" => id, "status" => status}, socket) do
    socket.assigns.current_user
    |> Accounts.update_user_status(Accounts.get_user(id), status)
    |> handle_user_change(socket)
  end

  defp event_class("granted"),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

  defp event_class(event) when event in ["denied", "locked_out"],
    do: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"

  defp event_class(event) when event in ["password_set", "password_changed"],
    do: "bg-indigo-50 text-indigo-700 dark:bg-indigo-950/50 dark:text-indigo-300"

  defp event_class(_), do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

  defp password_error_message(:mismatch), do: "新しいパスワードが一致しません。"
  defp password_error_message(:invalid_password), do: "現在の管理者パスワードが違います。"

  defp password_error_message(:too_short),
    do: "パスワードは #{AdminAccess.min_password_length()} 文字以上にしてください。"

  defp password_error_message(:surrounding_whitespace), do: "パスワードの前後に空白を含めないでください。"
  defp password_error_message(_), do: "管理者パスワードを変更できませんでした。"

  defp handle_user_change({:ok, user}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "#{user.email} を更新しました。")
     |> load_dashboard_data()}
  end

  defp handle_user_change({:error, :cannot_modify_self}, socket) do
    {:noreply, put_flash(socket, :error, "自分自身の権限や状態は変更できません。")}
  end

  defp handle_user_change({:error, :last_admin}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "昇格可能なアカウントを 0 件にはできません。先に別のアカウントに昇格を許可してください。"
     )}
  end

  defp handle_user_change({:error, _changeset}, socket) do
    {:noreply, put_flash(socket, :error, "ユーザーの更新に失敗しました。")}
  end

  # `<.input type="select">` wants {label, value} pairs; the identifiers themselves are too
  # terse to show to an operator.
  # Secrets are never echoed back into the form; the admin only needs to know whether one
  # is stored (N-610).
  defp secret_state(value) when is_binary(value) and value != "", do: "設定済み"
  defp secret_state(_), do: "未設定"

  defp provider_options(providers) do
    Enum.map(providers, fn provider -> {LLM.label(provider), provider} end)
  end

  defp load_dashboard_data(socket) do
    # 1. Batch history (spec F-338): recent runs, the one being inspected (latest unless the
    #    admin picked another row), and what the night-window trigger is doing.
    runs = Scheduler.list_runs(20)
    selected_id = socket.assigns[:selected_run_id]
    latest_run = Enum.find(runs, &(&1.id == selected_id)) || List.first(runs)
    item_logs = if latest_run, do: ItemLog.list_for_run(latest_run.id), else: []
    run_summaries = runs |> Enum.map(& &1.id) |> ItemLog.summaries()
    auto_status = Scheduler.auto_status()

    # 2. Coverage Stats
    total_chunks = Repo.aggregate(Chunk, :count, :id) || 0
    active_qas = Repo.one(from q in QAPair, where: q.status == "active", select: count(q.id)) || 0
    stale_qas = Repo.one(from q in QAPair, where: q.status == "stale", select: count(q.id)) || 0
    total_docs = Repo.aggregate(Document, :count, :id) || 0

    # 3. Documents
    docs = Documents.list_documents()

    # 4. Unanswered & Resolved questions
    unresolved_questions = QA.list_unresolved_questions()
    resolved_questions = QA.list_resolved_questions()

    # 5. Health & Runtime Mode
    health = HealthCheck.check()
    current_mode = Mode.current_mode()
    account = Accounts.get_account()
    setting = socket.assigns[:setting]
    users = Accounts.list_users()

    socket
    |> assign(:users, users)
    |> assign(:elevation_logs, AdminAccess.list_elevation_logs(100))
    |> assign(:admin_password_set?, AdminAccess.password_set?(setting))
    |> assign(:generation_provider, LLM.generation_provider(setting))
    |> assign(:embedding_provider, LLM.embedding_provider(setting))
    |> assign(:latest_run, latest_run)
    |> assign(:runs, runs)
    |> assign(:run_summaries, run_summaries)
    |> assign(:auto_status, auto_status)
    |> assign(:item_logs, item_logs)
    |> assign(:total_chunks, total_chunks)
    |> assign(:active_qas, active_qas)
    |> assign(:stale_qas, stale_qas)
    |> assign(:total_docs, total_docs)
    |> assign(:documents, docs)
    |> assign(:unresolved_questions, unresolved_questions)
    |> assign(:resolved_questions, resolved_questions)
    |> assign(:health, health)
    |> assign(:current_mode, current_mode)
    |> assign(:account, account)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      admin_elevated?={@admin_elevated?}
      admin_elevation_expires_at={@admin_elevation_expires_at}
      wide
    >
      <div class="space-y-6 pb-12">
        <%!-- Header Bar --%>
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-4 border-b border-zinc-200 dark:border-zinc-800">
          <div>
            <div class="flex items-center gap-2">
              <h1 class="font-bold text-2xl text-zinc-900 dark:text-zinc-100">管理ダッシュボード</h1>
            </div>
            <p class="text-xs text-zinc-500 mt-1">
              AskDrive の夜間バッチ、ナレッジカバレッジ、未回答質問、LLM プロバイダ、ユーザーを一元管理します。
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <%!-- Ingest only (spec 6.3.8 F-331): sync + indexing, no QA generation, so the
                  local model stays free for chat. The safe default for daytime runs. --%>
            <button
              id="trigger-ingest-btn"
              phx-click="trigger_batch"
              phx-value-kind="ingest_only"
              title="Drive の同期と取り込み（本文抽出・埋め込み）だけを行います。QA 生成は行わないため、実行中もチャットは通常どおり使えます。"
              class="text-xs px-3.5 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium shadow-sm flex items-center gap-1.5 transition"
            >
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> 取り込みのみ実行
            </button>
            <button
              id="trigger-batch-btn"
              phx-click="trigger_batch"
              phx-value-kind="full"
              data-confirm={
                if(@current_mode == :daytime,
                  do:
                    "現在は営業時間相です。QA 生成ありのバッチは生成モデルを長時間占有し、その間チャットは原文検索のみ（キーワード中心）になります。通常は「取り込みのみ実行」で十分です。実行しますか？",
                  else: "バッチ（QA 生成あり）を手動実行しますか？"
                )
              }
              class="text-xs px-3.5 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium flex items-center gap-1.5 transition"
            >
              <.icon name="hero-play" class="w-4 h-4" /> フル実行（QA 生成あり）
            </button>
          </div>
        </div>

        <%!-- Tab Navigation --%>
        <div class="flex border-b border-zinc-200 dark:border-zinc-800 gap-6 text-sm font-medium">
          <button
            phx-click="select_tab"
            phx-value-tab="overview"
            class={[
              "pb-3 border-b-2 transition",
              if(@current_tab == "overview",
                do: "border-indigo-600 text-indigo-600 dark:text-indigo-400 font-semibold",
                else: "border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              )
            ]}
          >
            概要・バッチ状況
          </button>
          <button
            phx-click="select_tab"
            phx-value-tab="questions"
            class={[
              "pb-3 border-b-2 transition flex items-center gap-2",
              if(@current_tab == "questions",
                do: "border-indigo-600 text-indigo-600 dark:text-indigo-400 font-semibold",
                else: "border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              )
            ]}
          >
            未回答・解消質問
            <%= if @unresolved_questions != [] do %>
              <span class="text-[10px] px-1.5 py-0.2 rounded-full bg-amber-100 text-amber-800 dark:bg-amber-900/50 dark:text-amber-300 font-bold">
                {length(@unresolved_questions)}
              </span>
            <% end %>
          </button>
          <button
            phx-click="select_tab"
            phx-value-tab="documents"
            class={[
              "pb-3 border-b-2 transition",
              if(@current_tab == "documents",
                do: "border-indigo-600 text-indigo-600 dark:text-indigo-400 font-semibold",
                else: "border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              )
            ]}
          >
            ドキュメント一覧 ({length(@documents)})
          </button>
          <button
            phx-click="select_tab"
            phx-value-tab="users"
            class={[
              "pb-3 border-b-2 transition",
              if(@current_tab == "users",
                do: "border-indigo-600 text-indigo-600 dark:text-indigo-400 font-semibold",
                else: "border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              )
            ]}
          >
            ユーザー管理 ({length(@users)})
          </button>
          <button
            phx-click="select_tab"
            phx-value-tab="audit"
            class={[
              "pb-3 border-b-2 transition",
              if(@current_tab == "audit",
                do: "border-indigo-600 text-indigo-600 dark:text-indigo-400 font-semibold",
                else: "border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              )
            ]}
          >
            昇格履歴
          </button>
          <button
            phx-click="select_tab"
            phx-value-tab="settings"
            class={[
              "pb-3 border-b-2 transition",
              if(@current_tab == "settings",
                do: "border-indigo-600 text-indigo-600 dark:text-indigo-400 font-semibold",
                else: "border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              )
            ]}
          >
            設定
          </button>
        </div>

        <%!-- Tab 1: Overview & Batch Status --%>
        <%= if @current_tab == "overview" do %>
          <div class="space-y-6">
            <%!-- KPI Cards --%>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">同期ドキュメント数</p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {@total_docs}
                </p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">総チャンク数</p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {@total_chunks}
                </p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">有効な想定QA数 (Tier 1)</p>
                <p class="text-2xl font-bold text-emerald-600 dark:text-emerald-400 mt-1">
                  {@active_qas}
                </p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">Stale QA数 (再生成待ち)</p>
                <p class="text-2xl font-bold text-amber-600 dark:text-amber-400 mt-1">
                  {@stale_qas}
                </p>
              </div>
            </div>

            <%!-- Nightly trigger status and batch history (spec F-338) --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-clock" class="w-5 h-5 text-indigo-600" /> 夜間バッチの自動実行と履歴
                </h2>
                <span class="text-xs text-zinc-500">
                  夜間枠: 毎日 {pad2(elem(@auto_status.window, 0))}:00〜翌 {pad2(
                    elem(@auto_status.window, 1)
                  )}:00（この PC のローカル時刻）
                </span>
              </div>

              <div
                id="auto-batch-status"
                class={[
                  "text-sm px-3 py-2 rounded-lg border",
                  case @auto_status.state do
                    :done ->
                      "bg-emerald-50 border-emerald-200 text-emerald-800 dark:bg-emerald-950/40 dark:border-emerald-900 dark:text-emerald-200"

                    :running ->
                      "bg-blue-50 border-blue-200 text-blue-800 dark:bg-blue-950/40 dark:border-blue-900 dark:text-blue-200"

                    :due ->
                      "bg-blue-50 border-blue-200 text-blue-800 dark:bg-blue-950/40 dark:border-blue-900 dark:text-blue-200"

                    :missed ->
                      "bg-amber-50 border-amber-200 text-amber-800 dark:bg-amber-950/40 dark:border-amber-900 dark:text-amber-200"
                  end
                ]}
              >
                <%= case @auto_status.state do %>
                  <% :running -> %>
                    バッチを実行中です。
                  <% :done -> %>
                    {Calendar.strftime(@auto_status.window_start, "%-m/%-d")} の夜間枠は実行済みです（#{@auto_status.run.id}・{trigger_label(
                      @auto_status.run.trigger
                    )}・{AskDrive.Clock.format(@auto_status.run.started_at, "%H:%M")} 開始・{status_label(
                      @auto_status.run.status
                    )}）。次回の自動実行: {Calendar.strftime(@auto_status.next_start, "%-m/%-d %H:%M")}
                  <% :due -> %>
                    夜間枠内で、この枠の自動実行はまだありません。1 分以内に自動で開始します。
                  <% :missed -> %>
                    {Calendar.strftime(@auto_status.window_start, "%-m/%-d")} の夜間枠では、自動実行の記録がありません（再起動で中断されたものは除く。手動実行は自動実行の代わりになりません）。次回の自動実行: {Calendar.strftime(
                      @auto_status.next_start,
                      "%-m/%-d %H:%M"
                    )}
                <% end %>
              </div>

              <%= if @runs == [] do %>
                <p class="text-xs text-zinc-500">バッチの実行履歴はまだありません。</p>
              <% else %>
                <div class="overflow-x-auto">
                  <table
                    id="batch-history"
                    class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                  >
                    <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                      <tr>
                        <th class="py-2 px-2">#</th>
                        <th class="py-2 px-2">開始</th>
                        <th class="py-2 px-2 text-right">所要時間</th>
                        <th class="py-2 px-2">起動</th>
                        <th class="py-2 px-2">種別</th>
                        <th class="py-2 px-2">状態</th>
                        <th class="py-2 px-2 text-right">取り込み（文書 / チャンク）</th>
                        <th class="py-2 px-2 text-right">失敗</th>
                        <th class="py-2 px-2 text-right">生成QA</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                      <tr
                        :for={run <- @runs}
                        id={"batch-run-#{run.id}"}
                        phx-click="select_run"
                        phx-value-id={run.id}
                        class={[
                          "cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition",
                          @latest_run && run.id == @latest_run.id &&
                            "bg-indigo-50/60 dark:bg-indigo-950/30"
                        ]}
                      >
                        <td class="py-2 px-2 font-mono">{run.id}</td>
                        <td class="py-2 px-2 font-mono whitespace-nowrap">
                          {AskDrive.Clock.format(run.started_at, "%m/%d %H:%M")}
                        </td>
                        <td class="py-2 px-2 text-right font-mono whitespace-nowrap">
                          {duration_label(run)}
                        </td>
                        <td class="py-2 px-2 whitespace-nowrap">{trigger_label(run.trigger)}</td>
                        <td class="py-2 px-2 whitespace-nowrap">
                          {if run.kind == "ingest_only", do: "取り込みのみ", else: "フル"}
                        </td>
                        <td class="py-2 px-2 whitespace-nowrap">
                          <span class={[
                            "px-2 py-0.5 rounded-full text-[10px] font-medium",
                            status_class(run.status)
                          ]}>
                            {status_label(run.status)}
                          </span>
                        </td>
                        <td class="py-2 px-2 text-right font-mono">
                          <% sum =
                            Map.get(@run_summaries, run.id, %{indexed: 0, chunks: 0, failed: 0}) %>
                          {sum.indexed || 0} / {sum.chunks || 0}
                        </td>
                        <td class={[
                          "py-2 px-2 text-right font-mono",
                          (Map.get(@run_summaries, run.id, %{failed: 0}).failed || 0) > 0 &&
                            "text-red-600"
                        ]}>
                          {Map.get(@run_summaries, run.id, %{failed: 0}).failed || 0}
                        </td>
                        <td class="py-2 px-2 text-right font-mono">{run.qa_generated || 0}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
                <p class="text-[11px] text-zinc-400">
                  行をクリックすると、下の「バッチ実行状況」にそのバッチの詳細（フェーズ別内訳・ファイル別ログ）を表示します。
                </p>
              <% end %>
            </div>

            <%!-- Latest Batch Run Card --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex items-center justify-between">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" /> バッチ実行状況
                  <span :if={@latest_run} class="text-xs font-normal text-zinc-400">
                    #{@latest_run.id}
                  </span>
                </h2>
                <div :if={@latest_run} class="flex items-center gap-2">
                  <span class={[
                    "text-xs px-2.5 py-1 rounded-full font-medium",
                    case @latest_run.status do
                      "completed" ->
                        "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300 border border-emerald-200/50"

                      "deadline_reached" ->
                        "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50"

                      "running" ->
                        "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300 border border-blue-200/50 animate-pulse"

                      _ ->
                        "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300 border border-red-200/50"
                    end
                  ]}>
                    {status_label(@latest_run.status)}
                  </span>
                  <span class="text-xs px-2.5 py-1 rounded-full font-medium bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300">
                    {trigger_label(@latest_run.trigger)}
                  </span>
                  <span
                    :if={@latest_run.kind == "ingest_only"}
                    class="text-xs px-2.5 py-1 rounded-full font-medium bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300"
                  >
                    取り込みのみ
                  </span>
                </div>
              </div>

              <%= if @latest_run do %>
                <div class="grid grid-cols-2 sm:grid-cols-5 gap-4 text-xs text-zinc-600 dark:text-zinc-400">
                  <div>
                    <span class="text-zinc-400 block">開始日時</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {AskDrive.Clock.format(@latest_run.started_at, "%Y-%m-%d %H:%M:%S")}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">終了日時</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {if @latest_run.finished_at,
                        do: AskDrive.Clock.format(@latest_run.finished_at, "%Y-%m-%d %H:%M:%S"),
                        else: "実行中..."}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">取り込み（成功文書 / チャンク）</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {count_logs(@item_logs, "embed_chunks", "indexed")} 件 / {sum_chunks(@item_logs)} 件
                      <span
                        :if={count_logs(@item_logs, "failed") > 0}
                        class="text-red-600 dark:text-red-400"
                      >
                        （失敗 {count_logs(@item_logs, "failed")} 件）
                      </span>
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">QA 生成（対象チャンク / 生成QA）</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {@latest_run.chunks_processed} 件 / {@latest_run.qa_generated} 件
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">未回答解消 / 残キュー</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {@latest_run.questions_resolved} 件 / {@latest_run.queue_remaining} 件
                    </span>
                  </div>
                </div>

                <%!-- Phase Breakdown List --%>
                <div class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-2">
                  <h3 class="text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                    フェーズ別内訳
                  </h3>
                  <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2 text-xs">
                    <%= for stat <- @latest_run.phase_stats do %>
                      <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800/80 flex items-center justify-between">
                        <span class="font-medium text-zinc-700 dark:text-zinc-300">
                          {stat.phase_name}
                        </span>
                        <div class="text-right text-zinc-500">
                          <span>{stat.duration_seconds}秒</span>
                          <span class="text-[10px] ml-1 text-zinc-400">({stat.items_count}件)</span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>

                <%!-- Per-file log (spec 6.3.5): what happened to each Drive file, and why --%>
                <div class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-2">
                  <h3 class="text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                    ファイル別ログ（{length(@item_logs)} 件・失敗を先頭に表示）
                  </h3>
                  <%= if @item_logs == [] do %>
                    <p class="text-xs text-zinc-500">
                      このバッチのファイル別ログはありません（v0.0.27 より前に実行したバッチには記録されていません）。
                    </p>
                  <% else %>
                    <div class="overflow-x-auto max-h-[28rem] overflow-y-auto">
                      <table
                        id="batch-item-logs"
                        class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                      >
                        <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800 sticky top-0 bg-white dark:bg-zinc-900">
                          <tr>
                            <th class="py-2 px-2">フェーズ</th>
                            <th class="py-2 px-2">結果</th>
                            <th class="py-2 px-2">ファイル</th>
                            <th class="py-2 px-2 text-right">チャンク</th>
                            <th class="py-2 px-2 text-right">時間</th>
                            <th class="py-2 px-2">詳細</th>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                          <tr :for={log <- @item_logs}>
                            <td class="py-2 px-2 whitespace-nowrap">{phase_label(log.phase)}</td>
                            <td class="py-2 px-2 whitespace-nowrap">
                              <span class={[
                                "px-2 py-0.5 rounded-full text-[10px] font-medium",
                                item_status_class(log.status)
                              ]}>
                                {item_status_label(log.status)}
                              </span>
                            </td>
                            <td class="py-2 px-2">
                              <span class="text-zinc-900 dark:text-zinc-100">{log.name}</span>
                              <span
                                :if={log.mime_type}
                                class="block font-mono text-[10px] text-zinc-400"
                              >
                                {log.mime_type}
                              </span>
                            </td>
                            <td class="py-2 px-2 text-right font-mono">{log.chunks || "—"}</td>
                            <td class="py-2 px-2 text-right font-mono whitespace-nowrap">
                              {if log.duration_ms, do: "#{log.duration_ms}ms", else: "—"}
                            </td>
                            <td class={[
                              "py-2 px-2 break-all",
                              log.status == "failed" && "text-red-600 dark:text-red-400"
                            ]}>
                              {log.message}
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <p class="text-xs text-zinc-500">夜間バッチの実行履歴はまだありません。</p>
              <% end %>
            </div>

            <%!-- System & Model Health --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-server" class="w-5 h-5 text-indigo-600" /> システム・推論基盤ステータス
              </h2>
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-4 text-xs">
                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">SQLite sqlite-vec</span>
                  <span class="font-semibold text-emerald-600 mt-1 block">
                    <%= case @health.sqlite_vec do %>
                      <% {:ok, v} -> %>
                        有効 (v{v})
                      <% {:error, err} -> %>
                        <span class="text-red-600">無効: {err}</span>
                    <% end %>
                  </span>
                </div>

                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">
                    回答生成 ({LLM.label(@generation_provider)})
                  </span>
                  <span class="font-semibold text-emerald-600 mt-1 block">
                    <%= case @health.llm_generation do %>
                      <% {:ok, info} -> %>
                        接続中 ({info})
                      <% {:error, err} -> %>
                        <span class="text-red-600">未接続: {err}</span>
                    <% end %>
                  </span>
                  <span class="text-[10px] text-zinc-400 mt-0.5 block">
                    {LLM.generation_model(@setting)}{if LLM.cloud_mode?(@setting),
                      do: "（クラウド）"}
                  </span>
                </div>

                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">
                    埋め込み ({LLM.label(@embedding_provider)})
                  </span>
                  <span class="font-semibold text-emerald-600 mt-1 block">
                    <%= case @health.llm_embedding do %>
                      <% {:ok, info} -> %>
                        接続中 ({info})
                      <% {:error, err} -> %>
                        <span class="text-red-600">未接続: {err}</span>
                    <% end %>
                  </span>
                  <span class="text-[10px] text-zinc-400 mt-0.5 block">
                    {@setting.embed_model} / {@setting.embedding_dim} 次元
                  </span>
                </div>

                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">pdftotext (PDF抽出)</span>
                  <span class="font-semibold mt-1 block">
                    {if @health.pdftotext == :ok,
                      do: "利用可能",
                      else: "未インストール (poppler)"}
                  </span>
                </div>

                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">pandoc (Office抽出)</span>
                  <span class="font-semibold mt-1 block">
                    {if @health.pandoc == :ok,
                      do: "利用可能",
                      else: "未インストール (pandoc)"}
                  </span>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Tab 2: Questions Loop --%>
        <%= if @current_tab == "questions" do %>
          <div class="space-y-6">
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center justify-between">
                <span class="flex items-center gap-2">
                  <.icon name="hero-question-mark-circle" class="w-5 h-5 text-amber-600" />
                  未回答質問（次回夜間バッチで最優先生成）
                </span>
                <span class="text-xs font-normal text-zinc-500">
                  {length(@unresolved_questions)} 件
                </span>
              </h2>

              <%= if @unresolved_questions == [] do %>
                <p class="text-xs text-zinc-500 py-4 text-center">現在、未解決の質問はありません。</p>
              <% else %>
                <div class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                  <%= for q <- @unresolved_questions do %>
                    <div class="py-3 flex items-start justify-between gap-4 text-xs">
                      <div>
                        <p class="font-medium text-zinc-900 dark:text-zinc-100">{q.question}</p>
                        <p class="text-[11px] text-zinc-400 mt-0.5">
                          到達: Tier {q.tier_reached} ・ 質問日時: {AskDrive.Clock.format(
                            q.asked_at,
                            "%Y-%m-%d %H:%M"
                          )}
                        </p>
                      </div>
                      <span class="text-[10px] px-2 py-0.5 rounded-full bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50">
                        優先度1
                      </span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-check-badge" class="w-5 h-5 text-emerald-600" />
                最近解消された質問 (前夜バッチによる成果)
              </h2>

              <%= if @resolved_questions == [] do %>
                <p class="text-xs text-zinc-500 py-4 text-center">解消済みの質問ログはありません。</p>
              <% else %>
                <div class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                  <%= for q <- @resolved_questions do %>
                    <div class="py-3 space-y-1.5 text-xs">
                      <div class="flex items-center justify-between">
                        <p class="font-medium text-zinc-900 dark:text-zinc-100">{q.question}</p>
                        <span class="text-[10px] text-zinc-400">
                          解消: {AskDrive.Clock.format(q.resolved_at, "%Y-%m-%d %H:%M")}
                        </span>
                      </div>
                      <%= if q.resolved_qa do %>
                        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-950 text-zinc-600 dark:text-zinc-400 text-[11px]">
                          <span class="font-semibold text-emerald-600">生成された回答:</span>
                          {q.resolved_qa.answer}
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Tab 3: Documents List --%>
        <%= if @current_tab == "documents" do %>
          <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
            <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center justify-between">
              <span>取り込み対象ドキュメント一覧</span>
              <span class="text-xs font-normal text-zinc-500">
                合計 {length(@documents)} 件
              </span>
            </h2>

            <%= if @documents == [] do %>
              <p class="text-xs text-zinc-500 py-8 text-center">
                同期されたドキュメントはまだありません。Google 連携および Drive 同期を行ってください。
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                  <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-3 px-2">ドキュメント名</th>
                      <th class="py-3 px-2">状態</th>
                      <th class="py-3 px-2">ファイル形式</th>
                      <th class="py-3 px-2">最終同期</th>
                      <th class="py-3 px-2 text-right">Drive</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                    <%= for doc <- @documents do %>
                      <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition">
                        <td class="py-3 px-2 font-medium text-zinc-900 dark:text-zinc-100">
                          {doc.name}
                          <%!-- Why a document didn't make it into the index (extraction or
                                embedding error, unsupported type), so a failed batch can be
                                diagnosed from here instead of from the server log. --%>
                          <p
                            :if={doc.status in ["failed", "skipped"] and doc.error}
                            class={[
                              "mt-1 font-normal text-[11px] break-all line-clamp-3",
                              if(doc.status == "failed",
                                do: "text-red-600 dark:text-red-400",
                                else: "text-zinc-500"
                              )
                            ]}
                            title={doc.error}
                          >
                            {doc.error}
                          </p>
                        </td>
                        <td class="py-3 px-2">
                          <span class={[
                            "px-2 py-0.5 rounded-full text-[10px] font-medium",
                            case doc.status do
                              "indexed" ->
                                "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

                              "pending" ->
                                "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300"

                              "skipped" ->
                                "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

                              _ ->
                                "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"
                            end
                          ]}>
                            {doc.status}
                          </span>
                        </td>
                        <td class="py-3 px-2 font-mono text-[11px] text-zinc-500">
                          {doc.mime_type}
                        </td>
                        <td class="py-3 px-2 text-zinc-400">
                          {if doc.synced_at,
                            do: AskDrive.Clock.format(doc.synced_at, "%Y-%m-%d %H:%M"),
                            else: "—"}
                        </td>
                        <td class="py-3 px-2 text-right">
                          <%= if doc.web_view_link do %>
                            <.link
                              href={doc.web_view_link}
                              target="_blank"
                              class="text-indigo-600 hover:text-indigo-800 dark:text-indigo-400 inline-flex items-center gap-0.5"
                            >
                              開く <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                            </.link>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Tab 4: User Management --%>
        <%= if @current_tab == "users" do %>
          <div class="space-y-6">
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                    <.icon name="hero-users" class="w-5 h-5 text-indigo-600" /> 登録ユーザー
                  </h2>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    利用者は初回ログイン時に自動登録され、全員が一般ユーザーとして開始します。<strong>「昇格可」</strong>に指定されたアカウントだけが、管理者パスワードを入力して一時的に管理者になれます。
                  </p>
                </div>
                <span class="text-xs text-zinc-500 shrink-0">合計 {length(@users)} 名</span>
              </div>

              <%= if Accounts.configured_admin_emails() != [] do %>
                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800 text-xs text-zinc-600 dark:text-zinc-400">
                  <span class="font-medium text-zinc-700 dark:text-zinc-300">
                    環境変数で昇格可に固定されているアドレス:
                  </span>
                  <span class="font-mono text-[11px] ml-1">
                    {Enum.join(Accounts.configured_admin_emails(), ", ")}
                  </span>
                  <p class="text-[11px] text-zinc-400 mt-1">
                    これらはログインのたびに昇格可フラグが再付与されます。画面から外しても元に戻ります。
                  </p>
                </div>
              <% end %>

              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                  <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-3 px-2">ユーザー</th>
                      <th class="py-3 px-2">管理者への昇格</th>
                      <th class="py-3 px-2">状態</th>
                      <th class="py-3 px-2">最終ログイン / 最終昇格</th>
                      <th class="py-3 px-2 text-right">操作</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                    <%= for user <- @users do %>
                      <tr
                        id={"user-row-#{user.id}"}
                        class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition"
                      >
                        <td class="py-3 px-2">
                          <div class="font-medium text-zinc-900 dark:text-zinc-100">
                            {user.name || "—"}
                            <span
                              :if={user.id == @current_user.id}
                              class="text-[10px] text-indigo-600 dark:text-indigo-400 ml-1"
                            >
                              (自分)
                            </span>
                          </div>
                          <div class="text-[11px] text-zinc-400 font-mono">{user.email}</div>
                        </td>
                        <td class="py-3 px-2">
                          <span class={[
                            "px-2 py-0.5 rounded-full text-[10px] font-medium",
                            if(user.admin_eligible,
                              do:
                                "bg-indigo-50 text-indigo-700 dark:bg-indigo-950/50 dark:text-indigo-300",
                              else: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"
                            )
                          ]}>
                            {if user.admin_eligible, do: "昇格可", else: "不可"}
                          </span>
                        </td>
                        <td class="py-3 px-2">
                          <span class={[
                            "px-2 py-0.5 rounded-full text-[10px] font-medium",
                            if(user.status == "active",
                              do:
                                "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
                              else: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"
                            )
                          ]}>
                            {if user.status == "active", do: "有効", else: "無効"}
                          </span>
                        </td>
                        <td class="py-3 px-2 text-zinc-400">
                          <div>
                            {if user.last_login_at,
                              do: AskDrive.Clock.format(user.last_login_at, "%Y-%m-%d %H:%M"),
                              else: "—"}
                          </div>
                          <div class="text-[10px]">
                            昇格: {if user.last_elevated_at,
                              do: AskDrive.Clock.format(user.last_elevated_at, "%Y-%m-%d %H:%M"),
                              else: "—"}
                          </div>
                        </td>
                        <td class="py-3 px-2">
                          <%!-- Self-modification and last-admin removal are rejected server
                                side too; hiding the buttons just avoids a pointless error. --%>
                          <div
                            :if={user.id != @current_user.id}
                            class="flex items-center justify-end gap-2"
                          >
                            <button
                              id={"toggle-eligible-#{user.id}"}
                              phx-click="set_admin_eligible"
                              phx-value-id={user.id}
                              phx-value-eligible={to_string(not user.admin_eligible)}
                              data-confirm={
                                if(user.admin_eligible,
                                  do: "#{user.email} から管理者への昇格資格を外しますか？",
                                  else:
                                    "#{user.email} に管理者への昇格を許可しますか？管理者パスワードを知っていれば設定と API キーを変更できるようになります。"
                                )
                              }
                              class="px-2.5 py-1 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-[11px] font-medium transition"
                            >
                              {if user.admin_eligible, do: "昇格を禁止", else: "昇格を許可"}
                            </button>
                            <button
                              id={"toggle-status-#{user.id}"}
                              phx-click="set_user_status"
                              phx-value-id={user.id}
                              phx-value-status={
                                if user.status == "active", do: "disabled", else: "active"
                              }
                              data-confirm={
                                if(user.status == "active",
                                  do: "#{user.email} を無効化しますか？ログインできなくなります。",
                                  else: "#{user.email} を再度有効化しますか？"
                                )
                              }
                              class={[
                                "px-2.5 py-1 rounded-lg text-[11px] font-medium transition",
                                if(user.status == "active",
                                  do:
                                    "bg-red-50 hover:bg-red-100 text-red-700 dark:bg-red-950/40 dark:hover:bg-red-900/60 dark:text-red-300",
                                  else:
                                    "bg-emerald-50 hover:bg-emerald-100 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-300"
                                )
                              ]}
                            >
                              {if user.status == "active", do: "無効化", else: "有効化"}
                            </button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Tab 5: Elevation Audit Log --%>
        <%= if @current_tab == "audit" do %>
          <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
            <div>
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-clipboard-document-list" class="w-5 h-5 text-indigo-600" />
                管理者権限の昇格履歴
              </h2>
              <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                どのアカウントから、いつ管理者権限へ昇格したかの記録です（直近 100 件）。失敗・解除・期限切れも残ります。この記録は削除も編集もできません。
              </p>
            </div>

            <%= if @elevation_logs == [] do %>
              <p class="text-xs text-zinc-500 py-8 text-center">昇格の記録はまだありません。</p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                  <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-3 px-2">日時</th>
                      <th class="py-3 px-2">アカウント</th>
                      <th class="py-3 px-2">イベント</th>
                      <th class="py-3 px-2">送信元 IP</th>
                      <th class="py-3 px-2">User-Agent</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                    <%= for log <- @elevation_logs do %>
                      <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition">
                        <td class="py-2.5 px-2 font-mono text-[11px] whitespace-nowrap">
                          {AskDrive.Clock.format(log.occurred_at, "%Y-%m-%d %H:%M:%S")}
                        </td>
                        <td class="py-2.5 px-2 font-mono text-[11px] text-zinc-900 dark:text-zinc-100">
                          {log.email}
                        </td>
                        <td class="py-2.5 px-2">
                          <span class={[
                            "px-2 py-0.5 rounded-full text-[10px] font-medium",
                            event_class(log.event)
                          ]}>
                            {AdminElevationLog.label(log.event)}
                          </span>
                        </td>
                        <td class="py-2.5 px-2 font-mono text-[11px]">{log.ip_address || "—"}</td>
                        <td
                          class="py-2.5 px-2 text-[10px] text-zinc-400 max-w-xs truncate"
                          title={log.user_agent}
                        >
                          {log.user_agent || "—"}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Tab 6: Settings Management --%>
        <%= if @current_tab == "settings" do %>
          <div class="space-y-6">
            <%!-- Card 1: Administrator password --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-shield-check" class="w-5 h-5 text-indigo-600" /> 管理者パスワード
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  管理画面へ昇格する際に入力するパスワードです。昇格可能なアカウント全員で共有します。退職者が出たときや漏洩が疑われるときは変更してください。
                </p>
              </div>

              <.form
                for={@password_form}
                id="admin-password-form"
                phx-submit="change_admin_password"
                class="grid grid-cols-1 sm:grid-cols-3 gap-4 items-end"
              >
                <.input
                  field={@password_form[:current]}
                  type="password"
                  value=""
                  label="現在のパスワード"
                  autocomplete="current-password"
                />
                <.input
                  field={@password_form[:new]}
                  type="password"
                  value=""
                  label={"新しいパスワード（#{AdminAccess.min_password_length()} 文字以上）"}
                  autocomplete="new-password"
                />
                <div class="flex items-end gap-3">
                  <div class="flex-1">
                    <.input
                      field={@password_form[:confirmation]}
                      type="password"
                      value=""
                      label="確認"
                      autocomplete="new-password"
                    />
                  </div>
                  <button
                    type="submit"
                    id="change-admin-password-btn"
                    class="px-4 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition whitespace-nowrap"
                  >
                    変更
                  </button>
                </div>
              </.form>

              <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 pt-2 border-t border-zinc-200/60 dark:border-zinc-800">
                <.input
                  field={@form[:admin_session_minutes]}
                  type="number"
                  label="昇格の有効時間 (分)"
                  min="1"
                  max="480"
                  form="settings-form"
                />
                <.input
                  field={@form[:admin_max_attempts]}
                  type="number"
                  label="ロックまでの失敗回数"
                  min="1"
                  max="50"
                  form="settings-form"
                />
                <.input
                  field={@form[:admin_lockout_minutes]}
                  type="number"
                  label="ロックアウト時間 (分)"
                  min="1"
                  max="1440"
                  form="settings-form"
                />
              </div>
              <p class="text-[11px] text-zinc-400">
                上記 3 項目は下の「設定を保存」で反映されます。
              </p>
            </div>

            <%!-- Card 2: Google Drive Sync Authentication --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex items-center justify-between">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cloud-arrow-down" class="w-5 h-5 text-indigo-600" />
                  Google Drive 同期認証
                </h2>
                <%= if Accounts.drive_connected?() do %>
                  <span class="text-xs px-2.5 py-1 rounded-full font-medium bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300 border border-emerald-200/50">
                    連携中: {Accounts.drive_identity()}
                  </span>
                <% else %>
                  <span class="text-xs px-2.5 py-1 rounded-full font-medium bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50">
                    未連携
                  </span>
                <% end %>
              </div>

              <div class="flex gap-2 p-1 rounded-xl bg-zinc-100 dark:bg-zinc-800 w-fit text-xs font-medium">
                <button
                  type="button"
                  id="drive-auth-mode-oauth"
                  phx-click="set_drive_auth_mode"
                  phx-value-mode="oauth"
                  class={[
                    "px-3 py-1.5 rounded-lg transition",
                    if(@setting.drive_auth_mode == "oauth",
                      do: "bg-white dark:bg-zinc-900 shadow-sm text-zinc-900 dark:text-zinc-100",
                      else: "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
                    )
                  ]}
                >
                  OAuth（専用アカウント）
                </button>
                <button
                  type="button"
                  id="drive-auth-mode-service-account"
                  phx-click="set_drive_auth_mode"
                  phx-value-mode="service_account"
                  class={[
                    "px-3 py-1.5 rounded-lg transition",
                    if(@setting.drive_auth_mode == "service_account",
                      do: "bg-white dark:bg-zinc-900 shadow-sm text-zinc-900 dark:text-zinc-100",
                      else: "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
                    )
                  ]}
                >
                  サービスアカウント
                </button>
              </div>

              <%= if @setting.drive_auth_mode == "service_account" do %>
                <p class="text-xs text-zinc-500 leading-relaxed">
                  ブラウザでの認可が不要なため、Google の redirect_uri 制限（生の IP アドレスや
                  <code
                    class="font-mono text-[11px]"
                    phx-no-curly-interpolation
                  >.local</code>
                  ホスト名の拒否）を回避できます。
                  <a
                    href="https://console.cloud.google.com/iam-admin/serviceaccounts"
                    target="_blank"
                    class="text-indigo-600 dark:text-indigo-400 underline"
                  >
                    Google Cloud Console
                  </a>
                  でサービスアカウントを作成し、JSON キーをダウンロードして貼り付けてください。作成後、同期対象の Drive フォルダをそのサービスアカウントのメールアドレス（<code
                    class="font-mono text-[11px]"
                    phx-no-curly-interpolation
                  >...@...iam.gserviceaccount.com</code>
                  ）と共有するのを忘れないでください。
                </p>

                <.form
                  for={@form}
                  id="service-account-form"
                  phx-submit="save_service_account"
                  class="space-y-3"
                >
                  <.input
                    field={@form[:drive_service_account_json]}
                    type="textarea"
                    value=""
                    rows="6"
                    label={"サービスアカウントの JSON キー（#{secret_state(@setting.drive_service_account_json)}）"}
                    placeholder={
                      ~s({"type": "service_account", "client_email": "...", "private_key": "...", ...})
                    }
                    class="font-mono text-[11px]"
                  />
                  <p class="text-[11px] text-zinc-500 -mt-1">
                    保存済みの場合は空欄のままで構いません（既存のキーを維持します）。
                  </p>
                  <.input
                    field={@form[:drive_impersonate_email]}
                    type="email"
                    label="なりすますユーザー（ドメイン全体の委任・任意）"
                    placeholder="sync@example.com"
                  />
                  <p class="text-[11px] text-zinc-500 leading-relaxed -mt-1">
                    同期対象が「組織内のユーザーのみアクセス可」の共有ドライブにある場合、サービスアカウント（組織外扱い）は共有に追加できません。
                    その場合はフォルダを閲覧できる社内ユーザーのメールアドレスを入力し、Google 管理コンソール →「セキュリティ」→「API の制御」→「ドメイン全体の委任」で
                    クライアント ID
                    <code class="font-mono">{service_account_client_id(@setting) ||
                      "（JSON キーの client_id）"}</code>
                    にスコープ
                    <code class="font-mono" phx-no-curly-interpolation>https://www.googleapis.com/auth/drive.readonly</code>
                    を許可してください。空欄ならサービスアカウント自身としてアクセスします。
                  </p>
                  <div class="flex flex-wrap items-center gap-3">
                    <button
                      type="submit"
                      id="save-service-account-btn"
                      class="inline-flex items-center gap-1.5 px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                    >
                      <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> 保存
                    </button>
                    <button
                      type="button"
                      id="test-service-account-btn"
                      phx-click="test_service_account"
                      class="px-3 py-2 rounded-xl border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium transition"
                    >
                      接続テスト
                    </button>
                    <button
                      :if={Accounts.drive_connected?()}
                      type="button"
                      id="disconnect-service-account-btn"
                      phx-click="disconnect_service_account"
                      data-confirm="保存済みのサービスアカウント認証情報を削除しますか？"
                      class="inline-flex items-center gap-1.5 px-3 py-2 rounded-xl bg-red-50 hover:bg-red-100 text-red-700 dark:bg-red-950/40 dark:hover:bg-red-900/60 dark:text-red-300 font-medium text-xs transition"
                    >
                      <.icon name="hero-x-circle" class="w-4 h-4" /> 削除
                    </button>
                  </div>
                  <%= case @service_account_test do %>
                    <% {:ok, message} -> %>
                      <p class="text-[11px] text-emerald-600 dark:text-emerald-400">{message}</p>
                    <% {:error, message} -> %>
                      <p class="text-[11px] text-red-600 dark:text-red-400">{message}</p>
                    <% _ -> %>
                  <% end %>
                </.form>
              <% else %>
                <p class="text-xs text-zinc-500 leading-relaxed">
                  全社公開マニュアル等の Google Drive フォルダにアクセス可能な <strong>システム管理用アカウント（または専用同期アカウント）</strong>
                  で連携してください。<br /> ※ 一般ユーザーがチャット画面で質問する際は、各自の通常アカウントで利用します。
                </p>

                <div class="flex flex-wrap items-center gap-3 pt-2">
                  <.link
                    href={~p"/auth/google/drive?#{[return_to: "/admin?tab=settings"]}"}
                    class="inline-flex items-center gap-2 px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                  >
                    <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4" />
                    {if @account, do: "専用 Google アカウントを再認可", else: "専用 Google アカウントで認可"}
                  </.link>

                  <%= if @account do %>
                    <.link
                      href={~p"/auth/google/disconnect?#{[return_to: "/admin?tab=settings"]}"}
                      class="inline-flex items-center gap-1.5 px-4 py-2 rounded-xl bg-red-50 hover:bg-red-100 text-red-700 dark:bg-red-950/40 dark:hover:bg-red-900/60 dark:text-red-300 font-medium text-xs transition"
                    >
                      <.icon name="hero-x-circle" class="w-4 h-4" /> 連携解除
                    </.link>
                  <% end %>
                </div>

                <p class="text-[11px] text-amber-700 dark:text-amber-300 leading-relaxed pt-1">
                  <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5 inline" />
                  この方式は Google Cloud Console にブラウザでアクセスした URL と完全一致するリダイレクト URI の登録が必要です。生の IP アドレスや
                  <code
                    class="font-mono text-[10px]"
                    phx-no-curly-interpolation
                  >.local</code>
                  ホスト名は Google 側で拒否されます。LAN 内からの利用でこの制約を避けたい場合は上の「サービスアカウント」を選んでください。
                </p>
              <% end %>
            </div>

            <%!-- Card 3: LLM Provider Settings --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-5">
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" /> LLM プロバイダ
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  回答生成と埋め込みで別々のプロバイダを選べます。埋め込みをローカルのまま据え置くと再インデックスが不要なため、まず生成だけを切り替える構成をおすすめします。
                </p>
              </div>

              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <%= for {role, label, provider, model} <- [
                      {:generation, "回答生成", @generation_provider, LLM.generation_model(@setting)},
                      {:embedding, "埋め込み", @embedding_provider, @setting.embed_model}
                    ] do %>
                  <div class="p-4 rounded-xl bg-zinc-50 dark:bg-zinc-950/60 border border-zinc-200/60 dark:border-zinc-800 space-y-2">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-semibold text-zinc-700 dark:text-zinc-300">{label}</span>
                      <span class={[
                        "text-[10px] px-2 py-0.5 rounded-full font-medium",
                        if(LLM.local?(provider),
                          do:
                            "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
                          else: "bg-amber-50 text-amber-800 dark:bg-amber-950/50 dark:text-amber-200"
                        )
                      ]}>
                        {if LLM.local?(provider), do: "ローカル", else: "外部 API"}
                      </span>
                    </div>
                    <div class="text-sm font-medium text-zinc-900 dark:text-zinc-100">
                      {LLM.label(provider)}
                    </div>
                    <div class="text-[11px] font-mono text-zinc-500 truncate">{model}</div>
                    <div class="text-[11px] text-zinc-400 truncate">
                      {LLM.base_url(provider, @setting)}
                    </div>
                    <div :if={LLM.requires_api_key?(provider)} class="text-[11px] text-zinc-500">
                      API キー: {LLM.masked_api_key(provider, @setting)}
                    </div>

                    <div class="pt-1 flex items-center gap-2">
                      <button
                        type="button"
                        id={"test-#{role}-btn"}
                        phx-click="test_connection"
                        phx-value-role={role}
                        class="px-2.5 py-1 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-[11px] font-medium transition"
                      >
                        接続テスト
                      </button>
                    </div>

                    <%= case Map.get(@connection_test, role) do %>
                      <% {:ok, message} -> %>
                        <p class="text-[11px] text-emerald-600 dark:text-emerald-400">{message}</p>
                      <% {:error, message} -> %>
                        <p class="text-[11px] text-red-600 dark:text-red-400">{message}</p>
                      <% _ -> %>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <div
                :if={not LLM.local?(@generation_provider) or not LLM.local?(@embedding_provider)}
                class="p-3 rounded-xl bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800/50 text-amber-800 dark:text-amber-200 text-xs leading-relaxed flex items-start gap-2"
              >
                <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0 mt-0.5" />
                <span>
                  外部 API が有効です。<strong>文書本文と質問がプロバイダに送信されます。</strong>
                  機密文書を扱う場合は Ollama または LM Studio に戻してください。
                </span>
              </div>

              <p class="text-[11px] text-zinc-400">
                値の変更は下の「システム・OAuth・バッチ設定」フォームから行います。
              </p>
            </div>

            <%!-- Card 4: System Settings Form --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-6">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-cog-6-tooth" class="w-5 h-5 text-indigo-600" /> システム・OAuth・バッチ設定
              </h2>

              <.form for={@form} id="settings-form" phx-submit="save_settings" class="space-y-5">
                <%!-- Google Cloud OAuth Credentials --%>
                <div class="space-y-3 p-4 rounded-xl bg-zinc-50 dark:bg-zinc-950/60 border border-zinc-200/60 dark:border-zinc-800">
                  <h3 class="font-semibold text-xs text-zinc-700 dark:text-zinc-300 flex items-center gap-1.5">
                    <.icon name="hero-key" class="w-4 h-4 text-indigo-500" /> Google Cloud OAuth 認証情報
                  </h3>
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:google_client_id]}
                      type="text"
                      label="OAuth クライアント ID (Client ID)"
                      placeholder="例: xxxxxxxx.apps.googleusercontent.com"
                    />
                    <.input
                      field={@form[:google_client_secret]}
                      type="password"
                      value=""
                      label={"OAuth クライアント シークレット（#{secret_state(@setting.google_client_secret)}）"}
                      placeholder="例: GOCSPX-xxxxxxxxxxxx"
                    />
                  </div>

                  <div class="text-xs text-zinc-500 space-y-1 pt-1">
                    <p class="font-medium text-zinc-700 dark:text-zinc-300">
                      Google Cloud Console に登録する「承認済みのリダイレクト URI」:
                    </p>
                    <div class="p-2 rounded bg-zinc-100 dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 font-mono text-[11px] text-indigo-600 dark:text-indigo-400 select-all">
                      http://localhost:4000/auth/google/callback（リモートホスト経由の場合はホスト名/IPに置換）
                    </div>
                  </div>
                </div>

                <%!-- LLM Provider Selection --%>
                <div class="space-y-3 p-4 rounded-xl bg-zinc-50 dark:bg-zinc-950/60 border border-zinc-200/60 dark:border-zinc-800">
                  <h3 class="font-semibold text-xs text-zinc-700 dark:text-zinc-300 flex items-center gap-1.5">
                    <.icon name="hero-cpu-chip" class="w-4 h-4 text-indigo-500" /> LLM プロバイダとモデル
                  </h3>

                  <%!-- Nightly batch: local LLM or cloud API (spec F-821). Both configurations
                        are kept so switching doesn't mean retyping model names. --%>
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    <.input
                      field={@form[:batch_llm_mode]}
                      type="select"
                      label="夜間バッチ（QA 生成）の実行方法"
                      options={[{"ローカル LLM", "local"}, {"クラウド API", "cloud"}]}
                    />
                    <.input
                      field={@form[:llm_max_tokens]}
                      type="number"
                      label="生成トークン上限 (外部 API)"
                      min="1"
                    />
                    <p class="text-[11px] text-zinc-500 leading-relaxed sm:pt-6">
                      クラウド API は高精度・高速ですが、夜間に全チャンクの本文が API 提供元に送信され、従量課金になります。
                    </p>
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:llm_provider]}
                      type="select"
                      label="ローカル LLM プロバイダ"
                      options={
                        provider_options(Enum.filter(LLM.generation_providers(), &LLM.local?/1))
                      }
                    />
                    <.input
                      field={@form[:batch_model]}
                      type="text"
                      label="ローカル LLM のモデル名"
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:cloud_llm_provider]}
                      type="select"
                      label="クラウド API プロバイダ"
                      options={provider_options(AskDrive.Settings.Setting.cloud_providers())}
                    />
                    <.input
                      field={@form[:cloud_llm_model]}
                      type="text"
                      label="クラウド API のモデル名"
                      placeholder="例: Gemini のモデル名"
                    />
                  </div>

                  <%!-- Chat answers can use their own (fast, cloud) provider while the
                        nightly batch keeps generating locally (spec F-415). --%>
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    <.input
                      field={@form[:chat_summary_provider]}
                      type="select"
                      label="チャット要約プロバイダ"
                      prompt="回答生成と同じ"
                      options={provider_options(LLM.generation_providers())}
                    />
                    <.input
                      field={@form[:chat_summary_model]}
                      type="text"
                      label="チャット要約モデル名"
                      placeholder="空欄なら生成モデル名"
                    />
                    <p class="text-[11px] text-zinc-500 leading-relaxed sm:pt-6">
                      夜間バッチ（QA 生成）は上の回答生成プロバイダ、チャットの要約はこちらを使います。クラウドを選ぶと、質問と検索された抜粋が API 提供元に送信されます。
                    </p>
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    <.input
                      field={@form[:embed_provider]}
                      type="select"
                      label="埋め込みプロバイダ"
                      options={provider_options(LLM.embedding_providers())}
                    />
                    <.input field={@form[:embed_model]} type="text" label="埋め込みモデル名" />
                    <.input
                      field={@form[:embedding_dim]}
                      type="number"
                      label="埋め込み次元"
                      min="64"
                      max="4096"
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:batch_num_ctx]}
                      type="number"
                      label="コンテキスト長 (num_ctx / Ollama のみ)"
                    />
                    <.input
                      field={@form[:llm_temperature]}
                      type="number"
                      step="0.1"
                      min="0.0"
                      max="2.0"
                      label="temperature (空欄でプロバイダ既定値)"
                    />
                  </div>

                  <p class="text-[11px] text-amber-700 dark:text-amber-300 leading-relaxed">
                    <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5 inline" />
                    埋め込みモデルまたは次元を変更すると、ベクトル仮想テーブルを再作成し、既存のベクトルをすべて破棄します。次回の夜間バッチで全チャンクを再ベクトル化するまで Tier 1 / Tier 2 は機能しません。
                  </p>
                </div>

                <%!-- Provider Endpoints and API Keys --%>
                <div class="space-y-3 p-4 rounded-xl bg-zinc-50 dark:bg-zinc-950/60 border border-zinc-200/60 dark:border-zinc-800">
                  <h3 class="font-semibold text-xs text-zinc-700 dark:text-zinc-300 flex items-center gap-1.5">
                    <.icon name="hero-key" class="w-4 h-4 text-indigo-500" /> プロバイダ接続情報
                  </h3>
                  <p class="text-[11px] text-zinc-500">
                    API キーは暗号化して保存されます。空欄のまま保存すると既存の値を維持します。使用しないプロバイダの欄は空のままで構いません。
                  </p>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:ollama_host]}
                      type="text"
                      label="Ollama エンドポイント"
                      placeholder={LLM.default_base_url("ollama")}
                    />
                    <.input
                      field={@form[:lmstudio_base_url]}
                      type="text"
                      label="LM Studio エンドポイント"
                      placeholder={LLM.default_base_url("lmstudio")}
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:anthropic_api_key]}
                      type="password"
                      value=""
                      label={"Anthropic Claude API キー（#{LLM.masked_api_key("anthropic", @setting)}）"}
                      placeholder="sk-ant-..."
                    />
                    <.input
                      field={@form[:anthropic_base_url]}
                      type="text"
                      label="Anthropic ベース URL"
                      placeholder={LLM.default_base_url("anthropic")}
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:gemini_api_key]}
                      type="password"
                      value=""
                      label={"Google Gemini API キー（#{LLM.masked_api_key("gemini", @setting)}）"}
                      placeholder="AIza..."
                    />
                    <.input
                      field={@form[:gemini_base_url]}
                      type="text"
                      label="Gemini ベース URL"
                      placeholder={LLM.default_base_url("gemini")}
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:openai_api_key]}
                      type="password"
                      value=""
                      label={"OpenAI API キー（#{LLM.masked_api_key("openai", @setting)}）"}
                      placeholder="sk-..."
                    />
                    <.input
                      field={@form[:openai_base_url]}
                      type="text"
                      label="OpenAI ベース URL"
                      placeholder={LLM.default_base_url("openai")}
                    />
                  </div>
                </div>

                <%!-- Drive & Domain Settings --%>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <.input
                    field={@form[:drive_folder_id]}
                    type="text"
                    label="Google Drive フォルダ ID / URL (drive_folder_id)"
                  />
                  <.input
                    field={@form[:drive_folder_name]}
                    type="text"
                    label="Drive フォルダ表示名 (drive_folder_name)"
                  />
                </div>

                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <.input
                    field={@form[:allowed_domain]}
                    type="text"
                    label="許可 Google Workspace ドメイン (例: company.com)"
                  />
                  <.input
                    field={@form[:tier1_threshold]}
                    type="number"
                    step="0.01"
                    min="0.5"
                    max="1.0"
                    label="QA 即答（Tier 1）の類似度しきい値（既定 0.90。下げるほど生成済み QA で即答しやすく、上げるほど要約・抜粋に回る）"
                  />
                </div>

                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <.input
                    field={@form[:batch_start_hour]}
                    type="number"
                    label="バッチ開始時刻 (時: 0〜23)"
                    min="0"
                    max="23"
                  />
                  <.input
                    field={@form[:batch_end_hour]}
                    type="number"
                    label="バッチ締切時刻 (時: 0〜23)"
                    min="0"
                    max="23"
                  />
                </div>

                <.input
                  field={@form[:maintenance_message]}
                  type="text"
                  label="メンテナンス告知メッセージ"
                />

                <div class="pt-2 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3">
                  <.input
                    field={@form[:maintenance_mode]}
                    type="checkbox"
                    label="メンテナンスモード（チャット画面を停止し告知を表示する）"
                  />
                  <.input
                    field={@form[:serve_stale_qa]}
                    type="checkbox"
                    label="無効化（Stale）されたQAを警告付きで配信する"
                  />
                  <.input
                    field={@form[:daytime_llm_enabled]}
                    type="checkbox"
                    label="営業時間中のLLM生成を例外的に許可する (RAM消費に注意)"
                  />
                  <.input
                    field={@form[:chat_summary_enabled]}
                    type="checkbox"
                    label="チャットで検索結果の AI 要約を表示する（回答生成プロバイダを使用。クラウドの場合は抜粋が社外に送信されます）"
                  />
                </div>

                <div class="pt-4 flex justify-end">
                  <button
                    type="submit"
                    id="save-settings-btn"
                    data-confirm="設定を保存します。埋め込みモデルまたは次元を変更した場合、ベクトルインデックスを再作成し全件の再ベクトル化が必要になります。続行しますか？"
                    class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                  >
                    設定を保存
                  </button>
                </div>
              </.form>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # A token alone proves only that Google accepted the key (and the delegation). What sync
  # actually needs is read access to the folder, which is exactly what failed with a bare
  # 404 when an org-only shared drive refused the service account — so check that too.
  defp check_drive_folder(%{drive_folder_id: folder_id}) when folder_id in [nil, ""] do
    {:ok, "トークンの取得に成功しました（#{Accounts.drive_identity()}）。同期フォルダが未設定のため、フォルダの読み取りは確認していません。"}
  end

  defp check_drive_folder(%{drive_folder_id: folder_id} = setting) do
    case Client.get_metadata(folder_id) do
      {:ok, folder} ->
        {:ok, "接続に成功しました（#{Accounts.drive_identity()}）。同期フォルダ「#{folder["name"]}」を読み取れます。"}

      {:error, "HTTP 404" <> _} ->
        {:error, folder_not_found_hint(setting)}

      {:error, reason} ->
        {:error, "トークンは取得できましたが、同期フォルダを読み取れませんでした: #{inspect(reason)}"}
    end
  end

  defp folder_not_found_hint(%{drive_impersonate_email: subject})
       when is_binary(subject) and subject != "" do
    "トークンは取得できましたが、#{subject} には同期フォルダの閲覧権限がありません。そのユーザーにフォルダ（または共有ドライブ）へのアクセス権を付与してください。"
  end

  defp folder_not_found_hint(_setting) do
    "トークンは取得できましたが、同期フォルダを読み取れません（Drive は権限のないファイルを「見つからない」と返します）。" <>
      "フォルダをサービスアカウントに共有してください。社内限定の共有ドライブでサービスアカウントを追加できない場合は、" <>
      "下の「なりすますユーザー」を設定してドメイン全体の委任を使ってください。"
  end

  defp service_account_client_id(%{drive_service_account_json: json})
       when is_binary(json) and json != "" do
    case ServiceAccount.parse(json) do
      {:ok, %{client_id: client_id}} -> client_id
      _ -> nil
    end
  end

  defp service_account_client_id(_setting), do: nil

  defp count_logs(logs, status), do: Enum.count(logs, &(&1.status == status))

  defp count_logs(logs, phase, status),
    do: Enum.count(logs, &(&1.phase == phase and &1.status == status))

  defp sum_chunks(logs) do
    logs
    |> Enum.filter(&(&1.phase == "embed_chunks" and &1.status == "indexed"))
    |> Enum.map(&(&1.chunks || 0))
    |> Enum.sum()
  end

  defp phase_label("sync"), do: "同期"
  defp phase_label("embed_chunks"), do: "取り込み"
  defp phase_label(other), do: other

  defp item_status_label("created"), do: "新規"
  defp item_status_label("updated"), do: "更新"
  defp item_status_label("unchanged"), do: "変更なし"
  defp item_status_label("deleted"), do: "削除"
  defp item_status_label("indexed"), do: "取り込み完了"
  defp item_status_label("empty"), do: "本文なし"
  defp item_status_label("skipped"), do: "対象外"
  defp item_status_label("failed"), do: "失敗"
  defp item_status_label(other), do: other

  defp item_status_class("failed"),
    do: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"

  defp item_status_class(status) when status in ["indexed", "created", "updated"],
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

  defp item_status_class(status) when status in ["empty", "skipped", "deleted"],
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

  defp item_status_class(_), do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

  defp status_label("completed"), do: "完了"
  defp status_label("running"), do: "実行中"
  defp status_label("aborted"), do: "中断（再起動）"
  defp status_label("failed"), do: "失敗"
  defp status_label("deadline_reached"), do: "時間切れ"
  defp status_label(other), do: other

  defp status_class("completed"),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

  defp status_class("running"),
    do: "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300 animate-pulse"

  defp status_class("deadline_reached"),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

  defp status_class(_), do: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"

  defp trigger_label("auto"), do: "自動"
  defp trigger_label(_), do: "手動"

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # An aborted run's finished_at is when the next boot noticed it, not when it stopped.
  defp duration_label(%{status: "aborted"}), do: "—（中断）"

  defp duration_label(%{started_at: s, finished_at: nil}) when not is_nil(s) do
    "#{format_seconds(DateTime.diff(DateTime.utc_now(), s))}〜"
  end

  defp duration_label(%{started_at: s, finished_at: f}) when not is_nil(s) and not is_nil(f),
    do: format_seconds(DateTime.diff(f, s))

  defp duration_label(_), do: "—"

  defp format_seconds(sec) when sec < 60, do: "#{sec}秒"
  defp format_seconds(sec) when sec < 3600, do: "#{div(sec, 60)}分#{rem(sec, 60)}秒"
  defp format_seconds(sec), do: "#{div(sec, 3600)}時間#{div(rem(sec, 3600), 60)}分"
end
