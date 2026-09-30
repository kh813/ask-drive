defmodule AskDriveWeb.ChatLive do
  use AskDriveWeb, :live_view

  alias AskDrive.{Accounts, Answering, ChatSummary, HealthCheck, LLM, Repo, Settings, Snippet}
  alias AskDrive.Accounts.{AdminAccess, User}
  alias AskDrive.Documents.Chunk

  @impl true
  def mount(_params, session, socket) do
    setting = Settings.get_setting!()
    chunk_count = Repo.aggregate(Chunk, :count) || 0
    health = HealthCheck.check()

    access_password_enabled = setting.access_password_enabled == true

    unlocked_in_session =
      AdminAccess.access_unlocked?(session["unlocked_app_#{socket.assigns.app.slug}"], setting)

    is_admin =
      User.admin_eligible?(socket.assigns.current_user) or
        Accounts.app_admin_eligible?(socket.assigns.current_user, socket.assigns.app.slug)

    access_locked? = access_password_enabled and not (unlocked_in_session or is_admin)

    {:ok,
     socket
     |> assign(:page_title, "AskDrive for #{socket.assigns.app.name}")
     |> assign(:drive_connected?, Accounts.drive_connected?())
     |> assign(:setting, setting)
     |> assign(:chunk_count, chunk_count)
     # Answering only needs the embedding provider: generation happens in the nightly batch.
     |> assign(:embedding_ok?, match?({:ok, _}, health.llm_embedding))
     |> assign(:embedding_provider_label, LLM.label(LLM.embedding_provider(setting)))
     |> assign(:admin_eligible?, User.admin_eligible?(socket.assigns.current_user))
     |> assign(:summary_local?, summary_local?(setting))
     |> assign(:access_locked?, access_locked?)
     |> assign(:access_password_form, to_form(%{"password" => ""}, as: :chat_access))
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

    if trimmed == "" or socket.assigns.loading do
      {:noreply, socket}
    else
      user_msg = %{
        id: System.unique_integer([:positive]),
        role: :user,
        content: trimmed,
        inserted_at: DateTime.utc_now()
      }

      # Answer off the LiveView process: a query embedding can wait on a busy local model
      # (e.g. while a batch is generating), and doing it inline froze the page with no
      # feedback until it finished. The question shows at once with a "searching" bubble.
      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [user_msg])
       |> assign(:loading, true)
       |> assign(:form, to_form(%{"question" => ""}))
       # bind: the task must search this app's database, not the platform's (spec 6.11)
       |> start_async(:answer, AskDrive.Apps.bind(fn -> Answering.ask(trimmed) end))}
    end
  end

  @impl true
  def handle_event("reset_chat", _params, socket) do
    {:noreply, assign(socket, :messages, [])}
  end

  @impl true
  def handle_async(:answer, {:ok, result}, socket) do
    summarise? = result.tier == 2 and result.chunks != [] and ChatSummary.enabled?()

    assistant_msg = %{
      id: System.unique_integer([:positive]),
      role: :assistant,
      tier: result.tier,
      content: result.answer,
      answer: result.answer,
      chunks: result.chunks,
      qa_pair: result.qa_pair,
      question: result.question,
      index_empty?: Map.get(result, :index_empty?, false),
      # Live AI summary of the excerpts (spec 6.4.4): shown above them, streamed in
      summary: if(summarise?, do: %{status: :running, text: "", thinking: ""}),
      inserted_at: DateTime.utc_now()
    }

    socket =
      socket
      |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
      |> assign(:loading, false)

    socket =
      if summarise? do
        lv = self()
        id = assistant_msg.id

        start_async(
          socket,
          {:summary, id},
          AskDrive.Apps.bind(fn ->
            ChatSummary.generate(result.question, result.chunks, fn event ->
              send(lv, {:summary_delta, id, event})
            end)
          end)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_async({:summary, id}, {:ok, {:ok, %{text: text, thinking: thinking}}}, socket) do
    {:noreply, update_summary(socket, id, &%{&1 | status: :done, text: text, thinking: thinking})}
  end

  def handle_async({:summary, id}, {:ok, {:error, reason}}, socket) do
    require Logger
    Logger.warning("ChatLive: summary failed: #{inspect(reason)}")
    {:noreply, update_summary(socket, id, &Map.merge(&1, %{status: :failed, error: reason}))}
  end

  def handle_async({:summary, id}, {:exit, reason}, socket) do
    require Logger
    Logger.error("ChatLive: summary crashed: #{inspect(reason)}")
    {:noreply, update_summary(socket, id, &Map.merge(&1, %{status: :failed, error: reason}))}
  end

  def handle_async(:answer, {:exit, reason}, socket) do
    require Logger
    Logger.error("ChatLive: answering crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:loading, false)
     |> put_flash(:error, "回答の検索中にエラーが発生しました。しばらくしてからもう一度お試しください。")}
  end

  @impl true
  def handle_info({:summary_delta, id, {:answer, delta}}, socket) do
    {:noreply, update_summary(socket, id, &%{&1 | text: &1.text <> delta})}
  end

  def handle_info({:summary_delta, id, :answer_reset}, socket) do
    {:noreply, update_summary(socket, id, &%{&1 | text: ""})}
  end

  def handle_info({:summary_delta, id, {:thinking, delta}}, socket) do
    {:noreply, update_summary(socket, id, &%{&1 | thinking: &1.thinking <> delta})}
  end

  defp update_summary(socket, id, fun) do
    messages =
      Enum.map(socket.assigns.messages, fn
        %{id: ^id, summary: %{} = summary} = msg -> %{msg | summary: fun.(summary)}
        msg -> msg
      end)

    assign(socket, :messages, messages)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      admin_elevated?={@admin_elevated?}
      admin_elevation_expires_at={@admin_elevation_expires_at}
      app={@app}
      apps={@apps}
    >
      <%= if @access_locked? do %>
        <div class="min-h-[50vh] flex items-center justify-center p-4">
          <div class="w-full max-w-md p-8 bg-white dark:bg-zinc-900 rounded-3xl border border-zinc-200/80 dark:border-zinc-800 shadow-xl space-y-6 text-center">
            <div class="w-14 h-14 mx-auto rounded-2xl bg-indigo-50 dark:bg-indigo-950/50 flex items-center justify-center text-indigo-600 dark:text-indigo-400">
              <.icon name="hero-lock-closed" class="w-7 h-7" />
            </div>
            <div>
              <h2 class="text-lg font-bold text-zinc-900 dark:text-zinc-100">
                合言葉を入力してください
              </h2>
              <p class="text-xs text-zinc-500 dark:text-zinc-400 mt-2 leading-relaxed">
                窓口「{@app.name}」のチャットを利用するにはアクセスパスワード（合言葉）が必要です。
              </p>
            </div>
            <%!-- a plain POST: the unlock is written to the session (30 days) --%>
            <.form
              for={@access_password_form}
              id="chat-access-form"
              action={"/#{@app.slug}/unlock"}
              method="post"
              class="space-y-4 text-left"
            >
              <.input
                field={@access_password_form[:password]}
                type="password"
                placeholder="合言葉を入力"
                autocomplete="current-password"
                value=""
                required
              />
              <button
                type="submit"
                id="chat-unlock-btn"
                class="w-full py-2.5 px-4 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
              >
                解除してチャットを開始
              </button>
            </.form>
          </div>
        </div>
      <% else %>
        <div class="flex flex-col h-[calc(100vh-7rem)]">
          <%!-- Status Bar --%>
          <div class="flex flex-wrap items-center justify-between gap-2 pb-3 mb-4 border-b border-zinc-200 dark:border-zinc-800">
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <%= if @drive_connected? do %>
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
          <%= if not @drive_connected? and not @setting.maintenance_mode do %>
            <div class="mb-4 p-4 rounded-xl bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800/50 text-amber-800 dark:text-amber-200 flex items-start justify-between gap-3">
              <div class="flex items-start gap-3">
                <.icon name="hero-information-circle" class="w-5 h-5 text-amber-600 shrink-0 mt-0.5" />
                <div>
                  <p class="font-medium text-sm">Google Drive が連携されていません</p>
                  <p class="text-xs mt-0.5 text-amber-700 dark:text-amber-300">
                    <%= cond do %>
                      <% @admin_elevated? -> %>
                        ドキュメントを取り込んで検索・回答を行うには、管理画面で Drive 連携を設定してください。
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
                href={@base_path <> "/admin?tab=settings"}
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
                              {if msg[:summary], do: "AI 要約と引用元", else: "関連しそうな箇所（原文抜粋）"}
                            </span>
                          <% 3 -> %>
                            <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50 dark:border-amber-800/50">
                              <.icon name="hero-clock" class="w-3.5 h-3.5" />
                              {if msg[:index_empty?],
                                do: "未回答（文書が未取り込み）",
                                else: "未回答（今夜のバッチで回答生成予定）"}
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
                                  生成日時: {AskDrive.Clock.format(
                                    msg.qa_pair.generated_at,
                                    "%Y-%m-%d %H:%M"
                                  )}
                                </span>
                              <% end %>
                            </div>
                          <% end %>
                        </div>
                      <% end %>

                      <%!-- Message Content / Explanation for Tier 3 --%>
                      <%= if msg.tier == 3 do %>
                        <div
                          :if={msg[:index_empty?]}
                          class="text-zinc-600 dark:text-zinc-400 text-xs leading-relaxed space-y-1"
                        >
                          <p>検索対象の文書がまだ1件も取り込まれていません。</p>
                          <p class="text-zinc-500">
                            Google Drive の同期・取り込みが完了していない可能性があります。管理者に確認してください（管理画面のドキュメント一覧で各文書の状態とエラーを確認できます）。質問内容は記録され、取り込み後の夜間バッチで回答生成の対象になります。
                          </p>
                        </div>
                        <div
                          :if={!msg[:index_empty?]}
                          class="text-zinc-600 dark:text-zinc-400 text-xs leading-relaxed space-y-1"
                        >
                          <p>この質問に関する明確な記載を現在のインデックスから特定できませんでした。</p>
                          <p class="text-zinc-500">
                            質問内容はシステムに記録されました。今夜の夜間バッチで全ドキュメントを対象に回答データを生成し、翌朝から即答できるようになります。
                          </p>
                        </div>
                      <% end %>

                      <%!-- Tier 2 Excerpt Sources --%>
                      <%= if msg.tier == 2 and msg.chunks != [] do %>
                        <div class="space-y-3">
                          <%!-- AI summary grounded in the excerpts below (spec 6.4.4) --%>
                          <div
                            :if={msg[:summary]}
                            id={"summary-#{msg.id}"}
                            class="p-3 rounded-xl bg-indigo-50/60 dark:bg-indigo-950/30 border border-indigo-200/60 dark:border-indigo-900/60 space-y-2"
                          >
                            <div class="flex items-center gap-1.5 text-xs font-semibold text-indigo-700 dark:text-indigo-300">
                              <.icon name="hero-sparkles" class="w-4 h-4" /> AI による要約
                              <span class="font-normal text-[10px] text-indigo-500/80">
                                （下の引用元の抜粋だけを根拠に生成）
                              </span>
                            </div>
                            <%= case msg.summary do %>
                              <% %{status: :failed} -> %>
                                <p class="text-xs text-zinc-500">
                                  要約を作成できませんでした。下の引用元の抜粋をご確認ください。
                                </p>
                              <% %{status: :running, text: "", thinking: thinking} when thinking != "" -> %>
                                <p class="text-xs text-zinc-500 flex items-center gap-1.5">
                                  <.icon name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
                                  考えています…（{String.length(thinking)}字）
                                </p>
                              <% %{status: :running, text: ""} -> %>
                                <p class="text-xs text-zinc-500 flex items-center gap-1.5">
                                  <.icon name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
                                  要約を作成しています…{if @summary_local?,
                                    do: "（ローカルの生成 AI では数十秒かかることがあります）"}
                                </p>
                              <% summary -> %>
                                <div class="text-sm text-zinc-800 dark:text-zinc-200 leading-relaxed">
                                  {summary_html(summary.text, msg.id, length(msg.chunks))}<span
                                    :if={summary.status == :running}
                                    class="inline-block w-1.5 h-3.5 ml-0.5 bg-indigo-400 animate-pulse align-middle"
                                  ></span>
                                </div>
                                <p :if={summary.status == :done} class="text-[10px] text-zinc-400">
                                  生成 AI の要約は誤りを含むことがあります。重要な判断の前に、必ず引用元をご確認ください。
                                </p>
                            <% end %>
                            <%!-- A reasoning model's thinking: kept, but collapsed by default --%>
                            <details
                              :if={Map.get(msg.summary, :thinking, "") != ""}
                              class="text-xs"
                            >
                              <summary class="cursor-pointer text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-200 select-none">
                                AI の思考過程を表示（{String.length(msg.summary.thinking)}字）
                              </summary>
                              <div class="mt-1.5 text-[11px] text-zinc-500 bg-white/60 dark:bg-zinc-900/60 p-2 rounded-md leading-relaxed max-h-60 overflow-y-auto">
                                {excerpt_html([{:text, msg.summary.thinking}])}
                              </div>
                            </details>
                          </div>

                          <p class="text-xs text-zinc-500">
                            {if msg[:summary], do: "引用元", else: "関連しそうな箇所です"}（原文の抜粋。質問の語を<mark class="bg-yellow-200 dark:bg-yellow-700/60 text-inherit rounded px-0.5">ハイライト</mark>しています）:
                          </p>
                          <div class="space-y-2">
                            <%= for {chunk, n} <- Enum.with_index(msg.chunks, 1) do %>
                              <div
                                id={"src-#{msg.id}-#{n}"}
                                class="p-3 rounded-xl bg-white dark:bg-zinc-950 border border-zinc-200/70 dark:border-zinc-800 space-y-1.5 scroll-mt-4 target:ring-2 target:ring-indigo-400"
                              >
                                <div class="flex items-center justify-between text-xs font-medium">
                                  <span class="text-indigo-600 dark:text-indigo-400 flex items-center gap-1 truncate max-w-md">
                                    <span class="shrink-0 px-1.5 py-0.5 rounded bg-indigo-600 text-white text-[10px] font-bold">
                                      [{n}]
                                    </span>
                                    <.icon name="hero-document-text" class="w-4 h-4 shrink-0" />
                                    {(chunk.document && chunk.document.name) || "ドキュメント"}
                                    <span
                                      :if={chunk.page}
                                      class="ml-1 px-1.5 py-0.5 rounded bg-indigo-50 dark:bg-indigo-950/60 text-[10px] font-semibold text-indigo-700 dark:text-indigo-300"
                                    >
                                      p.{chunk.page}
                                    </span>
                                  </span>
                                  <%= if chunk.document && chunk.document.web_view_link do %>
                                    <.link
                                      href={drive_link(chunk)}
                                      target="_blank"
                                      title={
                                        chunk.page &&
                                          "p.#{chunk.page} を開きます。Drive のビューアがページ指定に対応していない場合は、ビューアのページ欄で #{chunk.page} を指定してください"
                                      }
                                      class="text-[11px] text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 flex items-center gap-0.5 transition shrink-0"
                                    >
                                      {if chunk.page,
                                        do: "Drive で開く（p.#{chunk.page}）",
                                        else: "Drive で開く"}
                                      <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                                    </.link>
                                  <% end %>
                                </div>

                                <%= if chunk.heading && chunk.heading != "全体" do %>
                                  <div class="text-[11px] font-semibold text-zinc-700 dark:text-zinc-300">
                                    § {chunk.heading}
                                  </div>
                                <% end %>

                                <% snippet = Snippet.build(chunk.content, msg[:question]) %>
                                <div class="text-sm text-zinc-700 dark:text-zinc-300 bg-zinc-50 dark:bg-zinc-900 p-3 rounded-md leading-relaxed">
                                  {excerpt_html(snippet.segments, snippet.before?, snippet.after?)}
                                </div>
                                <details class="text-xs">
                                  <summary class="cursor-pointer text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-200 select-none">
                                    全文を表示
                                  </summary>
                                  <div class="mt-1.5 text-xs text-zinc-600 dark:text-zinc-400 bg-zinc-50 dark:bg-zinc-900 p-2 rounded-md leading-relaxed max-h-72 overflow-y-auto">
                                    {excerpt_html(Snippet.full(chunk.content, msg[:question]))}
                                  </div>
                                </details>
                              </div>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              <% end %>
              <div :if={@loading} id="answer-loading" class="flex justify-start">
                <div class="rounded-2xl rounded-tl-sm bg-zinc-50 dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 px-4 py-3 text-xs text-zinc-500 flex items-center gap-2 shadow-sm">
                  <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin" /> 回答を検索しています…
                </div>
              </div>
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
                disabled={@loading}
                class="px-5 py-3 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-sm flex items-center gap-1.5 shadow-sm transition disabled:opacity-50"
              >
                <span>送信</span>
                <.icon name="hero-paper-airplane" class="w-4 h-4" />
              </button>
            </.form>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp format_time(%DateTime{} = dt) do
    AskDrive.Clock.format(dt, "%H:%M")
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

  # Excerpt HTML is built here rather than in the template: the text keeps its line breaks
  # (as <br>) without relying on whitespace-pre-wrap, which would also render the
  # template's own indentation. Every piece of document text is escaped.
  defp excerpt_html(segments, before? \\ false, after? \\ false) do
    body =
      Enum.map(segments, fn
        {:hit, text} ->
          [
            ~s(<mark class="bg-yellow-200 dark:bg-yellow-700/60 text-inherit rounded px-0.5">),
            escape_lines(text),
            "</mark>"
          ]

        {:text, text} ->
          escape_lines(text)
      end)

    ellipsis = ~s(<span class="text-zinc-400">…</span>)

    Phoenix.HTML.raw([
      if(before?, do: ellipsis, else: ""),
      body,
      if(after?, do: ellipsis, else: "")
    ])
  end

  defp escape_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&(&1 |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()))
    |> Enum.intersperse("<br>")
  end

  # Drive's viewer is asked to open at the chunk's page. The fragment is not a documented
  # Drive feature: where it's ignored the file simply opens at the top, and the page badge
  # and tooltip tell the reader where to go (spec F-411).
  defp drive_link(%{document: %{web_view_link: link}, page: page})
       when is_binary(link) and is_integer(page),
       do: link <> "#page=#{page}"

  defp drive_link(%{document: %{web_view_link: link}}), do: link

  # The summary as HTML: escaped text, line breaks as <br>, and each citation "[n]" that
  # refers to an excerpt turned into a link to that excerpt's card.
  defp summary_html(text, msg_id, source_count) do
    text
    |> escape_lines()
    |> Enum.map(fn
      "<br>" ->
        "<br>"

      line ->
        Regex.replace(~r/\[(\d+)\]/, line, fn whole, n ->
          if String.to_integer(n) in 1..source_count//1 do
            ~s(<a href="#src-#{msg_id}-#{n}" class="inline-block px-1 rounded bg-indigo-100 dark:bg-indigo-900/60 text-indigo-700 dark:text-indigo-300 text-[11px] font-semibold no-underline hover:bg-indigo-200">[#{n}]</a>)
          else
            whole
          end
        end)
    end)
    |> Phoenix.HTML.raw()
  end

  defp summary_local?(setting) do
    {provider, _model} = ChatSummary.provider_and_model(setting)
    LLM.local?(provider)
  end
end
