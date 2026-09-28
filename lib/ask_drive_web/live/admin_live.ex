defmodule AskDriveWeb.AdminLive do
  @moduledoc """
  Admin Dashboard LiveView for AskDrive.
  Provides:
  - Batch status (latest run, phase breakdown, deadline truncation status)
  - Coverage statistics (total chunks, active QAs, stale QAs, unindexed chunks)
  - Unanswered questions and recently resolved questions
  - Synced documents list with statuses and Drive links
  - Ollama runtime model status and manual batch trigger
  - Settings management (batch hours, thresholds, models)
  """
  use AskDriveWeb, :live_view
  require Logger
  import Ecto.Query, warn: false

  alias AskDrive.Batch.{BatchRun, Scheduler}
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.QA.QAPair
  alias AskDrive.{Accounts, Documents, HealthCheck, QA, Repo, Settings}
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
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin?tab=#{tab}")}
  end

  @impl true
  def handle_event("trigger_batch", _params, socket) do
    Logger.info("AdminLive: Triggering manual batch run...")

    Task.start(fn ->
      Scheduler.run_batch()
    end)

    {:noreply,
     socket
     |> put_flash(:info, "夜間バッチの実行を開始しました。")
     |> load_dashboard_data()}
  end

  @impl true
  def handle_event("save_settings", %{"setting" => setting_params}, socket) do
    case Settings.update_setting(socket.assigns.setting, setting_params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign(:form, to_form(Settings.change_setting(updated)))
         |> put_flash(:info, "設定を保存しました。")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(:error, "設定の保存に失敗しました。入力内容を確認してください。")}
    end
  end

  defp load_dashboard_data(socket) do
    # 1. Latest Batch Run and stats
    latest_run =
      Repo.one(
        from b in BatchRun,
          order_by: [desc: b.started_at],
          limit: 1,
          preload: [:phase_stats]
      )

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

    socket
    |> assign(:latest_run, latest_run)
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
    <Layouts.app flash={@flash}>
      <div class="max-w-6xl mx-auto space-y-6 pb-12">
        <%!-- Header Bar --%>
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-4 border-b border-zinc-200 dark:border-zinc-800">
          <div>
            <div class="flex items-center gap-2">
              <h1 class="font-bold text-2xl text-zinc-900 dark:text-zinc-100">管理ダッシュボード</h1>
              <span class="text-xs px-2.5 py-0.5 rounded-full font-medium bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300">
                相: {@current_mode}
              </span>
            </div>
            <p class="text-xs text-zinc-500 mt-1">
              AskDrive の夜間バッチ、ナレッジカバレッジ、未回答質問、システム設定を一元管理します。
            </p>
          </div>

          <div class="flex items-center gap-3">
            <.link
              navigate={~p"/"}
              class="text-xs px-3 py-2 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium flex items-center gap-1.5 transition"
            >
              <.icon name="hero-chat-bubble-left-right" class="w-4 h-4" /> チャット画面へ
            </.link>

            <button
              id="trigger-batch-btn"
              phx-click="trigger_batch"
              data-confirm={
                if(@current_mode == :daytime,
                  do: "現在は営業時間相です。バッチを実行すると生成モデルがロードされ一時的にメモリを消費します。実行しますか？",
                  else: "バッチを手動実行しますか？"
                )
              }
              class="text-xs px-3.5 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium shadow-sm flex items-center gap-1.5 transition"
            >
              <.icon name="hero-play" class="w-4 h-4" /> 今すぐバッチ実行
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

            <%!-- Latest Batch Run Card --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex items-center justify-between">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" /> 直近の夜間バッチ実行状況
                </h2>
                <%= if @latest_run do %>
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
                    {@latest_run.status}
                  </span>
                <% end %>
              </div>

              <%= if @latest_run do %>
                <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 text-xs text-zinc-600 dark:text-zinc-400">
                  <div>
                    <span class="text-zinc-400 block">開始日時</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {Calendar.strftime(@latest_run.started_at, "%Y-%m-%d %H:%M:%S")}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">終了日時</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {if @latest_run.finished_at,
                        do: Calendar.strftime(@latest_run.finished_at, "%Y-%m-%d %H:%M:%S"),
                        else: "実行中..."}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">処理チャンク / 生成QA</span>
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
              <% else %>
                <p class="text-xs text-zinc-500">夜間バッチの実行履歴はまだありません。</p>
              <% end %>
            </div>

            <%!-- System & Model Health --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-server" class="w-5 h-5 text-indigo-600" /> システム・推論基盤ステータス
              </h2>
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 text-xs">
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
                  <span class="text-zinc-400 block">Ollama (推論サーバー)</span>
                  <span class="font-semibold text-emerald-600 mt-1 block">
                    <%= case @health.ollama do %>
                      <% {:ok, v} -> %>
                        接続中 (v{v})
                      <% {:error, err} -> %>
                        <span class="text-red-600">未接続: {err}</span>
                    <% end %>
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
                          到達: Tier {q.tier_reached} ・ 質問日時: {Calendar.strftime(
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
                          解消: {Calendar.strftime(q.resolved_at, "%Y-%m-%d %H:%M")}
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
                            do: Calendar.strftime(doc.synced_at, "%Y-%m-%d %H:%M"),
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

        <%!-- Tab 4: Settings Management --%>
        <%= if @current_tab == "settings" do %>
          <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-6">
            <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
              <.icon name="hero-cog-6-tooth" class="w-5 h-5 text-indigo-600" /> システム・バッチ設定
            </h2>

            <.form for={@form} id="settings-form" phx-submit="save_settings" class="space-y-4">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@form[:batch_model]}
                  type="text"
                  label="夜間生成モデル (batch_model: qwen3:4b)"
                />
                <.input
                  field={@form[:embed_model]}
                  type="text"
                  label="埋め込みモデル (embed_model: bge-m3)"
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

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@form[:similarity_threshold]}
                  type="number"
                  step="0.01"
                  min="0.0"
                  max="1.0"
                  label="Tier 1 類似度閾値 (0.0〜1.0)"
                />
                <.input
                  field={@form[:batch_num_ctx]}
                  type="number"
                  label="バッチ生成コンテキスト長 (num_ctx)"
                />
              </div>

              <div class="pt-2 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3">
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
              </div>

              <div class="pt-4 flex justify-end">
                <button
                  type="submit"
                  class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                >
                  設定を保存
                </button>
              </div>
            </.form>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
