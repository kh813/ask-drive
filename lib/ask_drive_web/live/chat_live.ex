defmodule AskDriveWeb.ChatLive do
  use AskDriveWeb, :live_view

  alias AskDrive.{Accounts, Answering, HealthCheck, LLM, Repo, Settings}
  alias AskDrive.Accounts.User
  alias AskDrive.Documents.Chunk

  @impl true
  def mount(_params, _session, socket) do
    account = Accounts.get_account()
    setting = Settings.get_setting!()
    chunk_count = Repo.aggregate(Chunk, :count) || 0
    health = HealthCheck.check()

    {:ok,
     socket
     |> assign(:page_title, "AskDrive - 社内文書検索チャット")
     |> assign(:account, account)
     |> assign(:setting, setting)
     |> assign(:chunk_count, chunk_count)
     # Answering only needs the embedding provider: generation happens in the nightly batch.
     |> assign(:embedding_ok?, match?({:ok, _}, health.llm_embedding))
     |> assign(:embedding_provider_label, LLM.label(LLM.embedding_provider(setting)))
     |> assign(:admin_eligible?, User.admin_eligible?(socket.assigns.current_user))
     |> assign(:messages, [])
     |> assign(:loading, false)
     |> assign(:form, to_form(%{"question" => ""}))}
  end

  @impl true
  def handle_event("validate", %{"question" => question}, socket) do
    {:noreply, assign(socket, form: to_form(%{"question" => question}))}
  end

  @impl true
  def handle_event("send_message", %{"question" => question}, socket) do
    trimmed = String.trim(question)

    if trimmed == "" do
      {:noreply, socket}
    else
      user_msg = %{
        id: System.unique_integer([:positive]),
        role: :user,
        content: trimmed,
        inserted_at: DateTime.utc_now()
      }

      # Run answering
      result = Answering.ask(trimmed)

      assistant_msg = %{
        id: System.unique_integer([:positive]),
        role: :assistant,
        tier: result.tier,
        content: result.answer,
        answer: result.answer,
        chunks: result.chunks,
        qa_pair: result.qa_pair,
        inserted_at: DateTime.utc_now()
      }

      updated_messages = socket.assigns.messages ++ [user_msg, assistant_msg]

      {:noreply,
       socket
       |> assign(:messages, updated_messages)
       |> assign(:form, to_form(%{"question" => ""}))}
    end
  end

  @impl true
  def handle_event("reset_chat", _params, socket) do
    {:noreply, assign(socket, :messages, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      admin_elevated?={@admin_elevated?}
      admin_elevation_expires_at={@admin_elevation_expires_at}
    >
      <div class="flex flex-col h-[calc(100vh-7rem)]">
        <%!-- Status Bar --%>
        <div class="flex flex-wrap items-center justify-between gap-2 pb-3 mb-4 border-b border-zinc-200 dark:border-zinc-800">
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <%= if @account do %>
              <span class="inline-flex items-center gap-1.5 text-emerald-600 dark:text-emerald-400">
                <span class="w-1.5 h-1.5 rounded-full bg-current"></span>
                {format_number(@chunk_count)} チャンクを検索対象にしています
              </span>
            <% else %>
              <span class="inline-flex items-center gap-1.5 text-amber-600 dark:text-amber-400">
                <span class="w-1.5 h-1.5 rounded-full bg-current"></span> Google Drive 未連携
              </span>
            <% end %>

            <%= if not @embedding_ok? do %>
              <span class="px-2 py-0.5 rounded-md bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300 border border-red-200 dark:border-red-800">
                {@embedding_provider_label} に接続できません
              </span>
            <% end %>
          </div>

          <%= if @messages != [] do %>
            <button
              id="reset-chat-btn"
              phx-click="reset_chat"
              class="text-xs px-3 py-1.5 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-600 dark:text-zinc-300 flex items-center gap-1 transition"
            >
              <.icon name="hero-trash" class="w-3.5 h-3.5" /> 会話をリセット
            </button>
          <% end %>
        </div>

        <%!-- Maintenance Mode Alert --%>
        <%= if @setting.maintenance_mode do %>
          <div class="mb-6 p-6 rounded-2xl bg-amber-50 dark:bg-amber-950/40 border border-amber-300 dark:border-amber-700 text-center space-y-3">
            <div class="w-12 h-12 rounded-2xl bg-amber-100 dark:bg-amber-900/60 text-amber-600 flex items-center justify-center mx-auto">
              <.icon name="hero-wrench-screwdriver" class="w-6 h-6" />
            </div>
            <div>
              <h2 class="font-bold text-base text-amber-900 dark:text-amber-100">
                現在システムメンテナンス中です
              </h2>
              <p class="text-xs text-amber-700 dark:text-amber-300 mt-1 max-w-md mx-auto">
                {@setting.maintenance_message || "データベースの更新またはアップデート作業を行っています。完了までしばらくお待ちください。"}
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Status Alert Banner --%>
        <%= if is_nil(@account) and not @setting.maintenance_mode do %>
          <div class="mb-4 p-4 rounded-xl bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800/50 text-amber-800 dark:text-amber-200 flex items-start justify-between gap-3">
            <div class="flex items-start gap-3">
              <.icon name="hero-information-circle" class="w-5 h-5 text-amber-600 shrink-0 mt-0.5" />
              <div>
                <p class="font-medium text-sm">Google Drive が連携されていません</p>
                <p class="text-xs mt-0.5 text-amber-700 dark:text-amber-300">
                  <%= cond do %>
                    <% @admin_elevated? -> %>
                      ドキュメントを取り込んで検索・回答を行うには、同期専用 Google アカウントを連携してください。
                    <% @admin_eligible? -> %>
                      Drive を連携するには、まず管理者権限に昇格してください。
                    <% true -> %>
                      まだドキュメントが取り込まれていません。管理者に Drive 連携を依頼してください。
                  <% end %>
                </p>
              </div>
            </div>
            <%!-- Connecting Drive needs an elevated session; an eligible user gets sent to
                  the password prompt first rather than a dead end. --%>
            <.link
              :if={@admin_elevated?}
              href={~p"/auth/google/drive"}
              class="text-xs px-3 py-1.5 rounded-lg bg-amber-600 hover:bg-amber-700 text-white font-medium shrink-0 transition"
            >
              今すぐ連携する
            </.link>
            <.link
              :if={not @admin_elevated? and @admin_eligible?}
              href={~p"/admin/elevate"}
              class="text-xs px-3 py-1.5 rounded-lg bg-amber-600 hover:bg-amber-700 text-white font-medium shrink-0 transition"
            >
              管理者として操作
            </.link>
          </div>
        <% end %>

        <%!-- Messages Scroll Area --%>
        <div id="chat-messages" class="flex-1 overflow-y-auto space-y-6 pr-2 mb-4 scroll-smooth">
          <%= if @messages == [] do %>
            <div class="h-full flex flex-col items-center justify-center text-center p-8 text-zinc-400 dark:text-zinc-500">
              <div class="w-12 h-12 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mb-3">
                <.icon name="hero-chat-bubble-left-right" class="w-6 h-6 text-zinc-400" />
              </div>
              <h3 class="font-medium text-zinc-700 dark:text-zinc-300 text-sm">
                Google Drive ドキュメントについて質問してください
              </h3>
              <p class="text-xs max-w-sm mt-1 text-zinc-500">
                社内規定、マニュアル、議事録など、取り込まれた文書から即座に原文抜粋を探索して回答します。
              </p>
            </div>
          <% else %>
            <%= for msg <- @messages do %>
              <%= if msg.role == :user do %>
                <div class="flex justify-end">
                  <div class="max-w-2xl rounded-2xl rounded-tr-sm bg-indigo-600 text-white px-4 py-3 shadow-sm text-sm">
                    <p class="whitespace-pre-wrap">{msg.content}</p>
                    <span class="text-[10px] text-indigo-200 block text-right mt-1">
                      {format_time(msg.inserted_at)}
                    </span>
                  </div>
                </div>
              <% else %>
                <div class="flex justify-start">
                  <div class="max-w-3xl w-full rounded-2xl rounded-tl-sm bg-zinc-50 dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 p-4 text-sm shadow-sm space-y-3">
                    <%!-- Tier Badge --%>
                    <div class="flex items-center justify-between pb-2 border-b border-zinc-200/60 dark:border-zinc-800">
                      <%= case msg.tier do %>
                        <% 2 -> %>
                          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300 border border-blue-200/50 dark:border-blue-800/50">
                            <.icon name="hero-document-magnifying-glass" class="w-3.5 h-3.5" />
                            関連しそうな箇所（原文抜粋）
                          </span>
                        <% 3 -> %>
                          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50 dark:border-amber-800/50">
                            <.icon name="hero-clock" class="w-3.5 h-3.5" /> 未回答（今夜のバッチで回答生成予定）
                          </span>
                        <% _ -> %>
                          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300">
                            <.icon name="hero-check-circle" class="w-3.5 h-3.5" /> 回答
                          </span>
                      <% end %>
                      <span class="text-[10px] text-zinc-400">
                        {format_time(msg.inserted_at)}
                      </span>
                    </div>

                    <%!-- Tier 0 / Tier 1 Direct Answer --%>
                    <%= if msg.tier in [0, 1] do %>
                      <div class="space-y-2">
                        <div class="text-zinc-900 dark:text-zinc-100 font-medium text-sm leading-relaxed whitespace-pre-wrap">
                          {msg.content}
                        </div>

                        <%= if msg.qa_pair do %>
                          <div class="pt-2 border-t border-zinc-200/50 dark:border-zinc-800/80 flex flex-wrap items-center justify-between gap-2 text-[11px] text-zinc-500">
                            <div class="flex items-center gap-2">
                              <%= if msg.qa_pair.document do %>
                                <span class="text-indigo-600 dark:text-indigo-400 font-medium flex items-center gap-1">
                                  <.icon name="hero-document-text" class="w-3.5 h-3.5" />
                                  {msg.qa_pair.document.name}
                                </span>
                                <%= if msg.qa_pair.document.web_view_link do %>
                                  <.link
                                    href={msg.qa_pair.document.web_view_link}
                                    target="_blank"
                                    class="text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 flex items-center gap-0.5"
                                  >
                                    Drive で開く
                                    <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                                  </.link>
                                <% end %>
                              <% end %>
                            </div>

                            <%= if msg.qa_pair.generated_at do %>
                              <span class="text-zinc-400">
                                生成日時: {Calendar.strftime(msg.qa_pair.generated_at, "%Y-%m-%d %H:%M")}
                              </span>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>

                    <%!-- Message Content / Explanation for Tier 3 --%>
                    <%= if msg.tier == 3 do %>
                      <div class="text-zinc-600 dark:text-zinc-400 text-xs leading-relaxed space-y-1">
                        <p>この質問に関する明確な記載を現在のインデックスから特定できませんでした。</p>
                        <p class="text-zinc-500">
                          質問内容はシステムに記録されました。今夜の夜間バッチで全ドキュメントを対象に回答データを生成し、翌朝から即答できるようになります。
                        </p>
                      </div>
                    <% end %>

                    <%!-- Tier 2 Excerpt Sources --%>
                    <%= if msg.tier == 2 and msg.chunks != [] do %>
                      <div class="space-y-3">
                        <p class="text-xs text-zinc-500">以下のドキュメントセクションが関連しています:</p>
                        <div class="space-y-2">
                          <%= for chunk <- msg.chunks do %>
                            <div class="p-3 rounded-xl bg-white dark:bg-zinc-950 border border-zinc-200/70 dark:border-zinc-800 space-y-1.5">
                              <div class="flex items-center justify-between text-xs font-medium">
                                <span class="text-indigo-600 dark:text-indigo-400 flex items-center gap-1 truncate max-w-md">
                                  <.icon name="hero-document-text" class="w-4 h-4 shrink-0" />
                                  {(chunk.document && chunk.document.name) || "ドキュメント"}
                                </span>
                                <%= if chunk.document && chunk.document.web_view_link do %>
                                  <.link
                                    href={chunk.document.web_view_link}
                                    target="_blank"
                                    class="text-[11px] text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 flex items-center gap-0.5 transition"
                                  >
                                    Drive で開く
                                    <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                                  </.link>
                                <% end %>
                              </div>

                              <%= if chunk.heading && chunk.heading != "全体" do %>
                                <div class="text-[11px] font-semibold text-zinc-700 dark:text-zinc-300">
                                  § {chunk.heading}
                                </div>
                              <% end %>

                              <div class="text-xs text-zinc-600 dark:text-zinc-400 font-mono bg-zinc-50 dark:bg-zinc-900 p-2 rounded-md leading-relaxed whitespace-pre-wrap max-h-48 overflow-y-auto">
                                {chunk.content}
                              </div>
                            </div>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% end %>
          <% end %>
        </div>

        <%!-- Bottom Input Bar --%>
        <div class="pt-2 border-t border-zinc-200 dark:border-zinc-800">
          <.form
            for={@form}
            id="chat-form"
            phx-change="validate"
            phx-submit="send_message"
            class="flex items-center gap-2"
          >
            <div class="flex-1 relative">
              <input
                type="text"
                name="question"
                id="chat-input"
                value={@form[:question].value}
                placeholder="Google Drive の文書について質問を入力してください..."
                class="w-full px-4 py-3 rounded-xl border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-sm text-zinc-900 dark:text-zinc-100 placeholder-zinc-400 focus:outline-none focus:ring-2 focus:ring-indigo-500 shadow-sm transition"
                autocomplete="off"
              />
            </div>
            <button
              type="submit"
              id="send-btn"
              class="px-5 py-3 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-sm flex items-center gap-1.5 shadow-sm transition disabled:opacity-50"
            >
              <span>送信</span>
              <.icon name="hero-paper-airplane" class="w-4 h-4" />
            </button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M")
  end

  defp format_time(_), do: ""

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(_), do: "0"
end
