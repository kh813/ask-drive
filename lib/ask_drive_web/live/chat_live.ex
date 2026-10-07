defmodule AskDriveWeb.ChatLive do
  use AskDriveWeb, :live_view

  alias AskDrive.{
    Accounts,
    Answering,
    ChatHistory,
    ChatSummary,
    HealthCheck,
    LLM,
    Repo,
    Settings,
    Snippet
  }

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
     # the user's earlier questions (F-430): listed when the panel is opened
     |> assign(:history_enabled?, ChatHistory.enabled?(socket.assigns.current_user))
     |> assign(:history_open?, false)
     |> assign(:history_query, "")
     |> assign(:history_count, 0)
     |> stream(:history, [])
     # threads (F-431): the one being answered, the one a follow-up is being typed for, and
     # the latest question (scrolled to)
     |> assign(:pending, nil)
     |> assign(:followup_thread, nil)
     |> assign(:followup_form, to_form(%{"question" => ""}, as: :followup))
     |> assign(:latest_question, nil)
     |> assign(:form, to_form(%{"question" => ""}))}
  end

  @impl true
  def handle_event("validate", %{"question" => question}, socket) do
    {:noreply, assign(socket, form: to_form(%{"question" => question}))}
  end

  # A new question (F-431): a thread of its own, answered without what came before it
  @impl true
  def handle_event("send_message", %{"question" => question}, socket) do
    {:noreply, ask(socket, question, Ecto.UUID.generate(), :new)}
  end

  # A follow-up to an answer: added to that thread, and answered in the light of it
  def handle_event("start_followup", %{"thread" => thread}, socket) do
    {:noreply,
     socket
     |> assign(:followup_thread, thread)
     |> assign(:followup_form, to_form(%{"question" => ""}, as: :followup))}
  end

  def handle_event("cancel_followup", _params, socket),
    do: {:noreply, assign(socket, :followup_thread, nil)}

  def handle_event(
        "send_followup",
        %{"followup" => %{"question" => question, "thread" => thread}},
        socket
      ) do
    if Enum.any?(socket.assigns.messages, &(&1.thread == thread)),
      do: {:noreply, ask(socket, question, thread, :follow_up)},
      else: {:noreply, assign(socket, :followup_thread, nil)}
  end

  # 停止: the search still running and/or the AI summaries still being written. Killing the
  # task closes its request, so a local model stops generating too.
  @impl true
  def handle_event("cancel_answer", _params, socket) do
    socket =
      if socket.assigns.loading,
        do:
          socket
          |> cancel_async(:answer)
          |> assign(:loading, false)
          |> assign(:pending, nil)
          |> put_flash(:info, gettext("Stopped answering the question.")),
        else: socket

    socket =
      socket.assigns.messages
      |> Enum.filter(&match?(%{summary: %{status: :running}}, &1))
      |> Enum.reduce(socket, fn msg, socket ->
        # kept as far as it got
        ChatHistory.put_summary(msg[:history_id], msg.summary.text)

        socket
        |> cancel_async({:summary, msg.id})
        |> update_summary(msg.id, &%{&1 | status: :cancelled})
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("reset_chat", _params, socket) do
    {:noreply, socket |> assign(:messages, []) |> assign(:followup_thread, nil)}
  end

  # The history panel (F-430): the user's own earlier threads, newest first
  def handle_event("toggle_history", _params, socket) do
    if socket.assigns.history_open? do
      {:noreply, assign(socket, :history_open?, false)}
    else
      {:noreply,
       socket
       |> assign(:history_open?, true)
       |> assign(:history_query, "")
       |> load_history()}
    end
  end

  def handle_event("history_search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:history_query, query) |> load_history()}
  end

  # Shows an earlier thread again — its question and every follow-up — below the
  # conversation; a follow-up to it continues the same thread
  def handle_event("history_open", %{"id" => key}, socket) do
    case ChatHistory.get_thread(socket.assigns.current_user, key) do
      [] ->
        {:noreply, socket}

      entries ->
        restored = history_messages(entries)
        others = Enum.reject(socket.assigns.messages, &(&1.thread == key))

        {:noreply,
         socket
         |> assign(:messages, others ++ restored)
         |> assign(:latest_question, hd(restored).id)
         |> assign(:history_open?, false)}
    end
  end

  def handle_event("history_delete", %{"id" => key}, socket) do
    case ChatHistory.delete_thread(socket.assigns.current_user, key) do
      {:ok, _} ->
        {:noreply,
         socket
         |> stream_delete_by_dom_id(:history, "history-#{key}")
         |> update(:history_count, &max(&1 - 1, 0))}

      _ ->
        {:noreply, socket}
    end
  end

  # Asks `question` in `thread`: a new one (`:new`) or a follow-up (`:follow_up`), which is
  # searched with the thread's earlier questions and summarised with its exchanges (F-431)
  defp ask(socket, question, thread, kind) do
    trimmed = String.trim(question)

    if trimmed == "" or socket.assigns.loading do
      socket
    else
      in_thread = Enum.filter(socket.assigns.messages, &(&1.thread == thread))
      context = if kind == :follow_up, do: thread_context(in_thread), else: []

      opts =
        if kind == :follow_up,
          do: [context: Enum.map(context, & &1.question), exclude_qa_ids: shown_qa_ids(in_thread)],
          else: []

      user_msg = %{
        id: System.unique_integer([:positive]),
        role: :user,
        thread: thread,
        follow_up?: kind == :follow_up,
        content: trimmed,
        inserted_at: DateTime.utc_now()
      }

      # Answer off the LiveView process: a query embedding can wait on a busy local model
      # (e.g. while a batch is generating), and doing it inline froze the page with no
      # feedback until it finished. The question shows at once with a "searching" bubble.
      socket
      |> assign(:messages, add_to_thread(socket.assigns.messages, thread, [user_msg]))
      |> assign(:latest_question, user_msg.id)
      |> assign(:loading, true)
      |> assign(:pending, %{thread: thread, context: context})
      |> assign(:followup_thread, nil)
      |> then(&if(kind == :new, do: assign(&1, :form, to_form(%{"question" => ""})), else: &1))
      # bind: the task must search this app's database, not the platform's (spec 6.11)
      |> start_async(:answer, AskDrive.Apps.bind(fn -> Answering.ask(trimmed, opts) end))
    end
  end

  # the thread's exchanges so far: each question with the answer shown for it
  defp thread_context(messages) do
    {turns, _question} =
      Enum.reduce(messages, {[], nil}, fn
        %{role: :user, content: question}, {turns, _} ->
          {turns, question}

        %{role: :assistant} = answer, {turns, question} when is_binary(question) ->
          {turns ++ [%{question: question, answer: answer_text(answer)}], nil}

        _, acc ->
          acc
      end)

    turns
  end

  defp answer_text(%{summary: %{text: text}}) when is_binary(text) and text != "", do: text
  defp answer_text(%{answer: answer}) when is_binary(answer), do: answer
  defp answer_text(_), do: nil

  defp shown_qa_ids(messages),
    do: for(%{role: :assistant, qa_pair: %{id: id}} <- messages, do: id)

  # after the thread's last message (its follow-ups stay together), or at the end
  defp add_to_thread(messages, thread, new) do
    case messages |> Enum.with_index() |> Enum.filter(fn {m, _} -> m.thread == thread end) do
      [] ->
        messages ++ new

      in_thread ->
        {_, last} = List.last(in_thread)
        {before, rest} = Enum.split(messages, last + 1)
        before ++ new ++ rest
    end
  end

  @impl true
  def handle_async(:answer, {:ok, result}, socket) do
    summarise? = result.tier == 2 and result.chunks != [] and ChatSummary.enabled?()
    %{thread: thread, context: context} = socket.assigns.pending
    entry = ChatHistory.record(socket.assigns.current_user, result, thread)

    assistant_msg = %{
      id: System.unique_integer([:positive]),
      role: :assistant,
      thread: thread,
      tier: result.tier,
      content: result.answer,
      answer: result.answer,
      chunks: result.chunks,
      qa_pair: result.qa_pair,
      question: result.question,
      # what was searched (a follow-up: with the thread's questions), highlighted in excerpts
      highlight: Map.get(result, :search_query, result.question),
      index_empty?: Map.get(result, :index_empty?, false),
      # Live AI summary of the excerpts (spec 6.4.4): shown above them, streamed in
      summary: if(summarise?, do: %{status: :running, text: "", thinking: ""}),
      history_id: entry && entry.id,
      inserted_at: DateTime.utc_now()
    }

    socket =
      socket
      |> assign(:messages, add_to_thread(socket.assigns.messages, thread, [assistant_msg]))
      |> assign(:loading, false)
      |> assign(:pending, nil)

    socket =
      if summarise? do
        lv = self()
        id = assistant_msg.id

        start_async(
          socket,
          {:summary, id},
          AskDrive.Apps.bind(fn ->
            ChatSummary.generate(
              result.question,
              result.chunks,
              fn event -> send(lv, {:summary_delta, id, event}) end,
              context: context
            )
          end)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_async({:summary, id}, {:ok, {:ok, %{text: text, thinking: thinking}}}, socket) do
    ChatHistory.put_summary(history_id(socket, id), text)
    {:noreply, update_summary(socket, id, &%{&1 | status: :done, text: text, thinking: thinking})}
  end

  def handle_async({:summary, id}, {:ok, {:error, reason}}, socket) do
    require Logger
    Logger.warning("ChatLive: summary failed: #{inspect(reason)}")
    {:noreply, update_summary(socket, id, &Map.merge(&1, %{status: :failed, error: reason}))}
  end

  # Stopped with 停止: the screen was already updated by "cancel_answer"
  def handle_async(_key, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

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
     |> assign(:pending, nil)
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

  defp history_id(socket, id) do
    Enum.find_value(socket.assigns.messages, fn
      %{id: ^id} = msg -> msg[:history_id]
      _ -> nil
    end)
  end

  defp load_history(socket) do
    threads = ChatHistory.list(socket.assigns.current_user, socket.assigns.history_query)

    socket
    |> assign(:history_count, length(threads))
    |> stream(:history, threads, reset: true)
  end

  # A thread's entries as question and answer bubbles, marked as from the history
  defp history_messages(entries) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} -> history_entry_messages(entry, index > 0) end)
  end

  defp history_entry_messages(entry, follow_up?) do
    restored = ChatHistory.restore(entry)

    user_msg = %{
      id: System.unique_integer([:positive]),
      role: :user,
      thread: entry.thread_key,
      follow_up?: follow_up?,
      content: entry.question,
      inserted_at: entry.asked_at,
      history_at: entry.asked_at
    }

    assistant_msg = %{
      id: System.unique_integer([:positive]),
      role: :assistant,
      thread: entry.thread_key,
      tier: entry.tier,
      content: entry.answer || "",
      answer: entry.answer,
      chunks: restored.chunks,
      qa_pair: restored.qa_pair,
      question: entry.question,
      index_empty?: entry.index_empty,
      summary: if(entry.summary, do: %{status: :done, text: entry.summary, thinking: ""}),
      # the excerpts were re-indexed since: what they were, instead
      missing_sources:
        if(entry.tier == 2 and restored.chunks == [], do: restored.sources, else: []),
      inserted_at: entry.asked_at,
      history_at: entry.asked_at
    }

    [user_msg, assistant_msg]
  end

  defp update_summary(socket, id, fun) do
    messages =
      Enum.map(socket.assigns.messages, fn
        # stopped: pieces still in the mailbox are dropped
        %{id: ^id, summary: %{status: :cancelled}} = msg -> msg
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
                {gettext("Enter passphrase")}
              </h2>
              <p class="text-xs text-zinc-500 dark:text-zinc-400 mt-2 leading-relaxed">
                {gettext("A passphrase is required to use the chat for desk \"%{name}\".",
                  name: @app.name
                )}
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
                placeholder={gettext("Enter passphrase")}
                autocomplete="current-password"
                value=""
                required
              />
              <button
                type="submit"
                id="chat-unlock-btn"
                class="w-full py-2.5 px-4 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
              >
                {gettext("Unlock and start chat")}
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
                  {gettext("%{count} chunks indexed for search", count: format_number(@chunk_count))}
                </span>
              <% else %>
                <span class="inline-flex items-center gap-1.5 text-amber-600 dark:text-amber-400">
                  <span class="w-1.5 h-1.5 rounded-full bg-current"></span> {gettext(
                    "Google Drive disconnected"
                  )}
                </span>
              <% end %>

              <%= if not @embedding_ok? do %>
                <span class="px-2 py-0.5 rounded-md bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300 border border-red-200 dark:border-red-800">
                  {gettext("Cannot connect to %{provider}", provider: @embedding_provider_label)}
                </span>
              <% end %>
            </div>

            <div class="flex items-center gap-2">
              <button
                :if={@history_enabled?}
                type="button"
                id="history-btn"
                phx-click="toggle_history"
                aria-expanded={to_string(@history_open?)}
                class={[
                  "text-xs px-3 py-1.5 rounded-lg border flex items-center gap-1 transition",
                  if(@history_open?,
                    do:
                      "border-indigo-300 bg-indigo-50 text-indigo-700 dark:border-indigo-800 dark:bg-indigo-950/50 dark:text-indigo-300",
                    else:
                      "border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-600 dark:text-zinc-300"
                  )
                ]}
              >
                <.icon name="hero-clock" class="w-3.5 h-3.5" /> {gettext("History")}
              </button>
              <%= if @messages != [] do %>
                <button
                  id="reset-chat-btn"
                  phx-click="reset_chat"
                  class="text-xs px-3 py-1.5 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-600 dark:text-zinc-300 flex items-center gap-1 transition"
                >
                  <.icon name="hero-trash" class="w-3.5 h-3.5" /> {gettext("Reset conversation")}
                </button>
              <% end %>
            </div>
          </div>

          <%!-- The user's own earlier questions (F-430) --%>
          <div
            :if={@history_open?}
            id="history-panel"
            class="mb-4 rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shadow-sm overflow-hidden"
          >
            <div class="flex flex-wrap items-center justify-between gap-2 px-4 py-3 border-b border-zinc-200/70 dark:border-zinc-800">
              <div>
                <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
                  {gettext("Your earlier questions")}
                </h3>
                <p class="text-[11px] text-zinc-500">
                  {gettext("Only you can see these. Open one to read its answer again.")}
                </p>
              </div>
              <form id="history-search-form" phx-change="history_search" phx-submit="history_search">
                <input
                  type="search"
                  name="q"
                  id="history-search"
                  value={@history_query}
                  phx-debounce="300"
                  placeholder={gettext("Search your questions")}
                  autocomplete="off"
                  class="w-56 px-3 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 text-xs focus:outline-none focus:ring-2 focus:ring-indigo-500 transition"
                />
              </form>
            </div>
            <ul
              id="history-list"
              phx-update="stream"
              class="max-h-72 overflow-y-auto divide-y divide-zinc-100 dark:divide-zinc-800"
            >
              <li
                id="history-empty"
                class="hidden only:block px-4 py-6 text-center text-xs text-zinc-500"
              >
                {if @history_query == "",
                  do: gettext("No questions yet."),
                  else: gettext("No questions match.")}
              </li>
              <li
                :for={{dom_id, entry} <- @streams.history}
                id={dom_id}
                class="group flex items-start gap-2 px-4 py-2.5 hover:bg-zinc-50 dark:hover:bg-zinc-800/60 transition"
              >
                <button
                  type="button"
                  id={"history-open-#{entry.id}"}
                  phx-click="history_open"
                  phx-value-id={entry.id}
                  class="flex-1 min-w-0 text-left"
                >
                  <span class="block text-sm text-zinc-800 dark:text-zinc-200 line-clamp-2 group-hover:text-indigo-700 dark:group-hover:text-indigo-300 transition">
                    {entry.title}
                  </span>
                  <span class="mt-0.5 flex items-center gap-2 text-[10px] text-zinc-400">
                    {format_datetime(entry.asked_at)}
                    <span
                      :if={entry.follow_ups > 0}
                      class="px-1.5 py-0.5 rounded-full bg-indigo-50 text-indigo-700 dark:bg-indigo-950/50 dark:text-indigo-300"
                    >
                      {gettext("%{count} follow-ups", count: entry.follow_ups)}
                    </span>
                    <span class={[
                      "px-1.5 py-0.5 rounded-full",
                      if(entry.tier == 3,
                        do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300",
                        else:
                          "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"
                      )
                    ]}>
                      {history_tier_label(entry.tier)}
                    </span>
                  </span>
                </button>
                <button
                  type="button"
                  id={"history-delete-#{entry.id}"}
                  phx-click="history_delete"
                  phx-value-id={entry.id}
                  data-confirm={gettext("Delete this question and its follow-ups from your history?")}
                  title={gettext("Delete")}
                  class="shrink-0 p-1.5 rounded-lg text-zinc-400 opacity-60 group-hover:opacity-100 hover:text-red-600 hover:bg-red-50 dark:hover:bg-red-950/40 transition"
                >
                  <.icon name="hero-trash" class="w-3.5 h-3.5" />
                </button>
              </li>
            </ul>
          </div>

          <%!-- Maintenance Mode Alert --%>
          <%= if @setting.maintenance_mode do %>
            <div class="mb-6 p-6 rounded-2xl bg-amber-50 dark:bg-amber-950/40 border border-amber-300 dark:border-amber-700 text-center space-y-3">
              <div class="w-12 h-12 rounded-2xl bg-amber-100 dark:bg-amber-900/60 text-amber-600 flex items-center justify-center mx-auto">
                <.icon name="hero-wrench-screwdriver" class="w-6 h-6" />
              </div>
              <div>
                <h2 class="font-bold text-base text-amber-900 dark:text-amber-100">
                  {gettext("System is currently under maintenance")}
                </h2>
                <p class="text-xs text-amber-700 dark:text-amber-300 mt-1 max-w-md mx-auto">
                  {@setting.maintenance_message ||
                    gettext("Database updates or maintenance are in progress. Please wait a moment.")}
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
                  <p class="font-medium text-sm">{gettext("Google Drive is not connected")}</p>
                  <p class="text-xs mt-0.5 text-amber-700 dark:text-amber-300">
                    <%= cond do %>
                      <% @admin_elevated? -> %>
                        {gettext(
                          "To ingest documents and search/answer, please configure Google Drive integration in Admin."
                        )}
                      <% @admin_eligible? -> %>
                        {gettext(
                          "To connect Drive, please elevate to administrator privileges first."
                        )}
                      <% true -> %>
                        {gettext(
                          "No documents have been ingested yet. Please ask an administrator to connect Google Drive."
                        )}
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
                {gettext("Connect now")}
              </.link>
              <.link
                :if={not @admin_elevated? and @admin_eligible?}
                href={~p"/admin/elevate"}
                class="text-xs px-3 py-1.5 rounded-lg bg-amber-600 hover:bg-amber-700 text-white font-medium shrink-0 transition"
              >
                {gettext("Act as administrator")}
              </.link>
            </div>
          <% end %>

          <%!-- Messages Scroll Area. Follows the conversation: each new message brings the
                latest question to the top, its answer below it (see .ChatScroll) --%>
          <div
            id="chat-messages"
            phx-hook=".ChatScroll"
            data-count={length(@messages)}
            data-latest={@latest_question}
            class="flex-1 overflow-y-auto space-y-6 pr-2 mb-4 scroll-smooth"
          >
            <%= if @messages == [] do %>
              <div class="h-full flex flex-col items-center justify-center text-center p-8 text-zinc-400 dark:text-zinc-500">
                <div class="w-12 h-12 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mb-3">
                  <.icon name="hero-chat-bubble-left-right" class="w-6 h-6 text-zinc-400" />
                </div>
                <h3 class="font-medium text-zinc-700 dark:text-zinc-300 text-sm">
                  {gettext("Ask questions about your Google Drive documents")}
                </h3>
                <p class="text-xs max-w-sm mt-1 text-zinc-500">
                  {gettext(
                    "Instant answers and document excerpts from your internal policies, manuals, and notes."
                  )}
                </p>
              </div>
            <% else %>
              <%!-- Threads (F-431): a question, its answer, and the follow-ups to it --%>
              <%= for {thread, thread_messages} <- threads(@messages) do %>
                <div
                  id={"thread-#{thread}"}
                  data-thread={thread}
                  class="space-y-4 p-3 sm:p-4 rounded-2xl border border-zinc-200/70 dark:border-zinc-800 bg-white/60 dark:bg-zinc-950/30"
                >
                  <%= for msg <- thread_messages do %>
                    <%= if msg.role == :user do %>
                      <div id={"msg-#{msg.id}"} data-role="user" class="flex justify-end scroll-mt-2">
                        <div class="max-w-2xl rounded-2xl rounded-tr-sm bg-indigo-600 text-white px-4 py-3 shadow-sm text-sm">
                          <p
                            :if={msg[:follow_up?]}
                            class="text-[10px] font-semibold text-indigo-200 mb-1 flex items-center gap-1"
                          >
                            <.icon name="hero-arrow-uturn-right" class="w-3 h-3" /> {gettext(
                              "Follow-up"
                            )}
                          </p>
                          <p class="whitespace-pre-wrap">{msg.content}</p>
                          <span class="text-[10px] text-indigo-200 block text-right mt-1">
                            <span :if={msg[:history_at]} class="mr-1">
                              <.icon name="hero-clock" class="w-3 h-3" /> {gettext("From history")}
                            </span>
                            {if msg[:history_at],
                              do: format_datetime(msg.history_at),
                              else: format_time(msg.inserted_at)}
                          </span>
                        </div>
                      </div>
                    <% else %>
                      <div id={"msg-#{msg.id}"} data-role="assistant" class="flex justify-start">
                        <div class="max-w-3xl w-full rounded-2xl rounded-tl-sm bg-zinc-50 dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 p-4 text-sm shadow-sm space-y-3">
                          <%!-- Tier Badge --%>
                          <div class="flex items-center justify-between pb-2 border-b border-zinc-200/60 dark:border-zinc-800">
                            <%= case msg.tier do %>
                              <% 2 -> %>
                                <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300 border border-blue-200/50 dark:border-blue-800/50">
                                  <.icon name="hero-document-magnifying-glass" class="w-3.5 h-3.5" />
                                  {if msg[:summary],
                                    do: gettext("AI Summary & Sources"),
                                    else: gettext("Relevant excerpts")}
                                </span>
                              <% 3 -> %>
                                <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50 dark:border-amber-800/50">
                                  <.icon name="hero-clock" class="w-3.5 h-3.5" />
                                  {if msg[:index_empty?],
                                    do: gettext("Unanswered (no documents ingested)"),
                                    else: gettext("Unanswered (will generate in nightly batch)")}
                                </span>
                              <% _ -> %>
                                <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300">
                                  <.icon name="hero-check-circle" class="w-3.5 h-3.5" /> {gettext(
                                    "Answer"
                                  )}
                                </span>
                            <% end %>
                            <span class="text-[10px] text-zinc-400">
                              {if msg[:history_at],
                                do: format_datetime(msg.history_at),
                                else: format_time(msg.inserted_at)}
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
                                          {gettext("Open in Drive")}
                                          <.icon
                                            name="hero-arrow-top-right-on-square"
                                            class="w-3 h-3"
                                          />
                                        </.link>
                                      <% end %>
                                    <% end %>
                                  </div>

                                  <%= if msg.qa_pair.generated_at do %>
                                    <span class="text-zinc-400">
                                      {gettext("Generated at: %{date}",
                                        date:
                                          AskDrive.Clock.format(
                                            msg.qa_pair.generated_at,
                                            "%Y-%m-%d %H:%M"
                                          )
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
                              <p>{gettext("No searchable documents have been ingested yet.")}</p>
                              <p class="text-zinc-500">
                                {gettext(
                                  "Google Drive synchronization or ingestion may not be finished. Please check with an administrator."
                                )}
                              </p>
                            </div>
                            <div
                              :if={!msg[:index_empty?]}
                              class="text-zinc-600 dark:text-zinc-400 text-xs leading-relaxed space-y-1"
                            >
                              <p>
                                {gettext(
                                  "Could not find a clear statement for this question in the current index."
                                )}
                              </p>
                              <p class="text-zinc-500">
                                {gettext(
                                  "Your question has been logged. Answers will be generated during the nightly batch."
                                )}
                              </p>
                            </div>
                          <% end %>

                          <%!-- From the history, its excerpts re-indexed since (F-430): the summary
                            as it was, and what the sources were --%>
                          <div
                            :if={msg[:missing_sources] not in [nil, []]}
                            id={"history-sources-#{msg.id}"}
                            class="space-y-2"
                          >
                            <div
                              :if={msg[:summary]}
                              class="p-3 rounded-xl bg-indigo-50/60 dark:bg-indigo-950/30 border border-indigo-200/60 dark:border-indigo-900/60 text-sm text-zinc-800 dark:text-zinc-200 leading-relaxed"
                            >
                              {summary_html(msg.summary.text, msg.id, 0)}
                            </div>
                            <p class="text-xs text-zinc-500">
                              {gettext(
                                "The documents have been updated since, so the excerpts can't be shown. Sources at the time:"
                              )}
                            </p>
                            <ol class="space-y-1 text-xs">
                              <li
                                :for={{source, n} <- Enum.with_index(msg.missing_sources, 1)}
                                class="flex items-center gap-1.5 text-zinc-700 dark:text-zinc-300"
                              >
                                <span class="shrink-0 px-1.5 py-0.5 rounded bg-indigo-600 text-white text-[10px] font-bold">
                                  [{n}]
                                </span>
                                {source["name"] || gettext("Document")}
                                <span :if={source["page"]} class="text-zinc-500">p.{source["page"]}</span>
                                <.link
                                  :if={source["link"]}
                                  href={source["link"]}
                                  target="_blank"
                                  class="text-[11px] text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 inline-flex items-center gap-0.5 transition"
                                >
                                  {gettext("Open in Drive")}
                                  <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                                </.link>
                              </li>
                            </ol>
                          </div>

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
                                  <.icon name="hero-sparkles" class="w-4 h-4" /> {gettext(
                                    "AI Summary"
                                  )}
                                  <span class="font-normal text-[10px] text-indigo-500/80">
                                    {gettext("(Grounded solely on the cited excerpts below)")}
                                  </span>
                                </div>
                                <%= case msg.summary do %>
                                  <% %{status: :cancelled, text: ""} -> %>
                                    <p class="text-xs text-zinc-500">
                                      {gettext("Summary stopped. Please check the excerpts below.")}
                                    </p>
                                  <% %{status: :failed} -> %>
                                    <p class="text-xs text-zinc-500">
                                      {gettext(
                                        "Could not create summary. Please check the excerpts below."
                                      )}
                                    </p>
                                  <% %{status: :running, text: "", thinking: thinking} when thinking != "" -> %>
                                    <p class="text-xs text-zinc-500 flex items-center gap-1.5">
                                      <.icon name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
                                      {gettext("Thinking… (%{count} chars)",
                                        count: String.length(thinking)
                                      )}
                                    </p>
                                  <% %{status: :running, text: ""} -> %>
                                    <p class="text-xs text-zinc-500 flex items-center gap-1.5">
                                      <.icon name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
                                      {gettext("Generating summary…")}{if @summary_local?,
                                        do: gettext(" (local LLMs may take several seconds)")}
                                    </p>
                                  <% summary -> %>
                                    <div class="text-sm text-zinc-800 dark:text-zinc-200 leading-relaxed">
                                      {summary_html(summary.text, msg.id, length(msg.chunks))}<span
                                        :if={summary.status == :running}
                                        class="inline-block w-1.5 h-3.5 ml-0.5 bg-indigo-400 animate-pulse align-middle"
                                      ></span>
                                    </div>
                                    <p
                                      :if={summary.status == :cancelled}
                                      class="text-[10px] text-zinc-400"
                                    >
                                      {gettext("(Stopped)")}
                                    </p>
                                    <p :if={summary.status == :done} class="text-[10px] text-zinc-400">
                                      {gettext(
                                        "AI summaries may contain errors. Always verify key details against the cited sources."
                                      )}
                                    </p>
                                <% end %>
                                <%!-- A reasoning model's thinking: kept, but collapsed by default --%>
                                <details
                                  :if={Map.get(msg.summary, :thinking, "") != ""}
                                  class="text-xs"
                                >
                                  <summary class="cursor-pointer text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-200 select-none">
                                    {gettext("Show AI thinking process (%{count} chars)",
                                      count: String.length(msg.summary.thinking)
                                    )}
                                  </summary>
                                  <div class="mt-1.5 text-[11px] text-zinc-500 bg-white/60 dark:bg-zinc-900/60 p-2 rounded-md leading-relaxed max-h-60 overflow-y-auto">
                                    {excerpt_html([{:text, msg.summary.thinking}])}
                                  </div>
                                </details>
                              </div>

                              <%!-- Follow-up right after the answer, before the excerpts that
                                    would push it out of sight --%>
                              <.followup_controls
                                :if={msg.id == List.last(thread_messages).id}
                                thread={thread}
                                followup_thread={@followup_thread}
                                followup_form={@followup_form}
                                loading={@loading}
                              />

                              <p class="text-xs text-zinc-500">
                                {if msg[:summary],
                                  do: gettext("Sources"),
                                  else: gettext("Relevant excerpts")} {gettext(
                                  "(Excerpts with search terms highlighted):"
                                )}
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
                                        {(chunk.document && chunk.document.name) ||
                                          gettext("Document")}
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
                                              "p.#{chunk.page}"
                                          }
                                          class="text-[11px] text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 flex items-center gap-0.5 transition shrink-0"
                                        >
                                          {if chunk.page,
                                            do:
                                              gettext("Open in Drive (p.%{page})", page: chunk.page),
                                            else: gettext("Open in Drive")}
                                          <.icon
                                            name="hero-arrow-top-right-on-square"
                                            class="w-3 h-3"
                                          />
                                        </.link>
                                      <% end %>
                                    </div>

                                    <%= if chunk.heading && chunk.heading != "全体" do %>
                                      <div class="text-[11px] font-semibold text-zinc-700 dark:text-zinc-300">
                                        § {chunk.heading}
                                      </div>
                                    <% end %>

                                    <% snippet =
                                      Snippet.build(chunk.content, msg[:highlight] || msg[:question]) %>
                                    <%!-- 3 lines so the follow-up stays in sight; click to open or
                                          close (「全文を表示」 has the whole chunk) --%>
                                    <%!-- the clamp is on the inner block: on the padded one, the 4th line peeked through --%>
                                    <div
                                      phx-click={
                                        JS.toggle_class("line-clamp-3", to: "#excerpt-#{msg.id}-#{n}")
                                      }
                                      title={gettext("Click to show or hide the whole excerpt")}
                                      class="cursor-pointer text-sm text-zinc-700 dark:text-zinc-300 bg-zinc-50 dark:bg-zinc-900 p-3 rounded-md leading-relaxed hover:bg-zinc-100 dark:hover:bg-zinc-800/80 transition-colors"
                                    >
                                      <div id={"excerpt-#{msg.id}-#{n}"} class="line-clamp-3">
                                        {excerpt_html(
                                          snippet.segments,
                                          snippet.before?,
                                          snippet.after?
                                        )}
                                      </div>
                                    </div>
                                    <details class="text-xs">
                                      <summary class="cursor-pointer text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-200 select-none">
                                        {gettext("Show full text")}
                                      </summary>
                                      <div class="mt-1.5 text-xs text-zinc-600 dark:text-zinc-400 bg-zinc-50 dark:bg-zinc-900 p-2 rounded-md leading-relaxed max-h-72 overflow-y-auto">
                                        {excerpt_html(
                                          Snippet.full(
                                            chunk.content,
                                            msg[:highlight] || msg[:question]
                                          )
                                        )}
                                      </div>
                                    </details>
                                  </div>
                                <% end %>
                              </div>
                            </div>
                          <% end %>

                          <%!-- Follow-up for an answer without excerpts: at its end --%>
                          <.followup_controls
                            :if={
                              msg.id == List.last(thread_messages).id and
                                not (msg.tier == 2 and msg.chunks != [])
                            }
                            thread={thread}
                            followup_thread={@followup_thread}
                            followup_form={@followup_form}
                            loading={@loading}
                          />
                        </div>
                      </div>
                    <% end %>
                  <% end %>
                  <div
                    :if={(@loading and @pending) && @pending.thread == thread}
                    id="answer-loading"
                    class="flex justify-start"
                  >
                    <div class="rounded-2xl rounded-tl-sm bg-zinc-50 dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 px-4 py-3 text-xs text-zinc-500 flex items-center gap-2 shadow-sm">
                      <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin" /> {gettext(
                        "Searching for answers…"
                      )}
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatScroll">
            // When a message is added — a question or a follow-up sent, its answer arriving, or
            // a thread opened from the history — bring the latest question (data-latest; a
            // follow-up may be in a thread above the last) to the top of the chat area, with
            // its answer below: a long answer is then read from its start. Scrolling again when
            // the answer arrives matters: when the question was sent, there may not have been
            // enough below it to bring it to the top. Updates that add no message (a summary
            // being written) leave the scroll position alone, so it can be read undisturbed.
            export default {
              mounted() {
                this.count = this.el.dataset.count
              },
              updated() {
                if (this.el.dataset.count === this.count) return
                const grew = Number(this.el.dataset.count) > Number(this.count)
                this.count = this.el.dataset.count
                if (!grew) return
                const latest = this.el.dataset.latest
                const last = latest && document.getElementById(`msg-${latest}`)
                if (!last) return
                const top = last.getBoundingClientRect().top - this.el.getBoundingClientRect().top
                this.el.scrollTo({top: this.el.scrollTop + top - 8, behavior: "smooth"})
              }
            }
          </script>

          <%!-- Bottom Input Bar: a new question (a thread of its own, F-431) --%>
          <div class="pt-2 border-t border-zinc-200 dark:border-zinc-800 space-y-1.5">
            <p :if={@messages != []} id="new-question-hint" class="text-[11px] text-zinc-500">
              {gettext(
                "This starts a new question, unrelated to the ones above. To ask more about an answer, use \"Ask a follow-up about this answer\" under it."
              )}
            </p>
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
                  placeholder={gettext("Ask a new question about Google Drive documents...")}
                  class="w-full px-4 py-3 rounded-xl border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-sm text-zinc-900 dark:text-zinc-100 placeholder-zinc-400 focus:outline-none focus:ring-2 focus:ring-indigo-500 shadow-sm transition"
                  autocomplete="off"
                />
              </div>
              <button
                :if={@loading or summarising?(@messages)}
                type="button"
                id="stop-btn"
                phx-click="cancel_answer"
                title={gettext("Stop answering")}
                class="px-4 py-3 rounded-xl border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 hover:bg-red-50 hover:border-red-300 hover:text-red-700 dark:hover:bg-red-950/40 dark:hover:text-red-300 text-zinc-700 dark:text-zinc-200 font-medium text-sm flex items-center gap-1.5 shadow-sm transition"
              >
                <.icon name="hero-stop-circle" class="w-4 h-4" />
                <span>{gettext("Stop")}</span>
              </button>
              <button
                type="submit"
                id="send-btn"
                disabled={@loading}
                class="px-5 py-3 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-sm flex items-center gap-1.5 shadow-sm transition disabled:opacity-50"
              >
                <.icon name="hero-plus" class="w-4 h-4" />
                <span>{gettext("New question")}</span>
              </button>
            </.form>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  # 「この回答に追加で質問」 and, once pressed, its input (F-431): under a thread's last answer
  attr :thread, :string, required: true
  attr :followup_thread, :string, default: nil
  attr :followup_form, :any, required: true
  attr :loading, :boolean, default: false

  def followup_controls(assigns) do
    ~H"""
    <%= cond do %>
      <% @followup_thread == @thread -> %>
        <.form
          for={@followup_form}
          id={"followup-form-#{@thread}"}
          phx-submit="send_followup"
          class="flex flex-wrap items-center gap-2 pl-1"
        >
          <input type="hidden" name="followup[thread]" value={@thread} />
          <input
            type="text"
            name="followup[question]"
            id={"followup-input-#{@thread}"}
            value=""
            phx-mounted={JS.focus()}
            placeholder={gettext("Ask more about this answer...")}
            autocomplete="off"
            class="flex-1 min-w-[12rem] px-3 py-2 rounded-xl border border-indigo-300 dark:border-indigo-800 bg-white dark:bg-zinc-900 text-sm text-zinc-900 dark:text-zinc-100 placeholder-zinc-400 focus:outline-none focus:ring-2 focus:ring-indigo-500 transition"
          />
          <button
            type="submit"
            id={"followup-send-#{@thread}"}
            disabled={@loading}
            class="px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium flex items-center gap-1.5 shadow-sm transition disabled:opacity-50"
          >
            <.icon name="hero-arrow-uturn-right" class="w-3.5 h-3.5" /> {gettext("Ask a follow-up")}
          </button>
          <button
            type="button"
            id={"followup-cancel-#{@thread}"}
            phx-click="cancel_followup"
            class="px-3 py-2 rounded-xl text-xs text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition"
          >
            {gettext("Cancel")}
          </button>
        </.form>
      <% true -> %>
        <div class="flex justify-start pl-1">
          <button
            type="button"
            id={"followup-btn-#{@thread}"}
            phx-click="start_followup"
            phx-value-thread={@thread}
            disabled={@loading}
            class="text-xs px-3 py-1.5 rounded-lg border border-indigo-200 dark:border-indigo-900 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-50 dark:hover:bg-indigo-950/40 flex items-center gap-1.5 transition disabled:opacity-40"
          >
            <.icon name="hero-arrow-uturn-right" class="w-3.5 h-3.5" /> {gettext(
              "Ask a follow-up about this answer"
            )}
          </button>
        </div>
    <% end %>
    """
  end

  # the messages by thread, in the order the threads appear
  defp threads(messages) do
    messages
    |> Enum.chunk_by(& &1.thread)
    |> Enum.map(fn [first | _] = in_thread -> {first.thread, in_thread} end)
  end

  defp summarising?(messages),
    do: Enum.any?(messages, &match?(%{summary: %{status: :running}}, &1))

  defp format_datetime(%DateTime{} = dt), do: AskDrive.Clock.format(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(_), do: ""

  defp history_tier_label(3), do: gettext("Unanswered")
  defp history_tier_label(2), do: gettext("Excerpts")
  defp history_tier_label(_), do: gettext("Answer")

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
