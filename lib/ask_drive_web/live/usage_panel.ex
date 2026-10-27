defmodule AskDriveWeb.UsagePanel do
  @moduledoc """
  The 「利用状況」 tab: on a desk's admin screen, who asks the most (questions, tokens,
  solved rate) and the questions asked often (spec F-1415); on the platform's, each person's
  questions and tokens added up over every desk (F-1416). The per-person figures are counts
  only, never what they asked. Events go to `AskDriveWeb.AdminLive`.
  """
  use AskDriveWeb, :html

  alias AskDrive.Usage

  attr :scope, :atom, required: true
  attr :report, :map, required: true
  attr :sort, :atom, required: true

  def usage_tab(assigns) do
    ~H"""
    <div id="usage-tab" class="space-y-6">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <p class="text-xs text-zinc-500 leading-relaxed max-w-2xl">
          <%= if @scope == :platform do %>
            {gettext(
              "Each person's questions and the tokens answering them used, added up over every desk. Only the numbers are shown, never what they asked."
            )}
          <% else %>
            {gettext(
              "Who uses this desk the most, and the questions asked often. Only the numbers are shown per person, never what they asked."
            )}
          <% end %>
          {gettext("Kept for %{days} days.", days: Usage.retention_days())}
        </p>
        <div
          id="usage-periods"
          class="inline-flex shrink-0 p-0.5 rounded-xl bg-zinc-100 dark:bg-zinc-800 text-xs font-medium"
        >
          <button
            :for={days <- Usage.periods()}
            type="button"
            id={"usage-period-#{days}"}
            phx-click="usage_period"
            phx-value-days={days}
            class={[
              "px-3 py-1.5 rounded-lg transition",
              if(@report.days == days,
                do: "bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 shadow-sm",
                else: "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              )
            ]}
          >
            {gettext("%{days} days", days: days)}
          </button>
        </div>
      </div>

      <div id="usage-cards" class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <.card label={gettext("People who asked")} icon="hero-users">
          <.big_number value={@report.users} />
          <span class="text-xs font-normal text-zinc-500">{gettext("people")}</span>
          <:note :if={@scope == :platform}>
            {gettext("Over %{count} desk(s)", count: @report.desks)}
          </:note>
        </.card>
        <.card label={gettext("Questions")} icon="hero-chat-bubble-left-right">
          <.big_number value={@report.questions} />
          <span class="text-xs font-normal text-zinc-500">{gettext("times")}</span>
        </.card>
        <.card label={gettext("Tokens answering them used")} icon="hero-cpu-chip">
          <span class="text-indigo-600 dark:text-indigo-400">
            <.big_number value={@report.tokens} />
          </span>
          <:note>
            {gettext("The search and the AI summary (the nightly batch is not included)")}
          </:note>
        </.card>
      </div>

      <.people scope={@scope} people={@report.people} sort={@sort} />

      <.frequent :if={@scope == :app} questions={@report.frequent} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true
  slot :note

  defp card(assigns) do
    ~H"""
    <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
      <p class="text-xs font-medium text-zinc-500 flex items-center gap-1.5">
        <.icon name={@icon} class="w-4 h-4 text-zinc-400" />
        {@label}
      </p>
      <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1 whitespace-nowrap">
        {render_slot(@inner_block)}
      </p>
      <p :for={note <- @note} class="text-[11px] text-zinc-400 mt-1">{render_slot(note)}</p>
    </div>
    """
  end

  attr :scope, :atom, required: true
  attr :people, :list, required: true
  attr :sort, :atom, required: true

  defp people(assigns) do
    ~H"""
    <div
      id="usage-people"
      class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
    >
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
        <h3 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
          <.icon name="hero-user-group" class="w-5 h-5 text-indigo-600" />
          {gettext("Active users")}
        </h3>
        <div class="inline-flex items-center gap-1 text-xs">
          <span class="text-zinc-500 mr-1">{gettext("Sort by")}</span>
          <button
            :for={{by, label} <- [{:questions, gettext("Questions")}, {:tokens, gettext("Tokens")}]}
            type="button"
            id={"usage-sort-#{by}"}
            phx-click="usage_sort"
            phx-value-by={by}
            class={[
              "px-2.5 py-1 rounded-lg border transition",
              if(@sort == by,
                do:
                  "border-indigo-200 bg-indigo-50 text-indigo-700 dark:border-indigo-900 dark:bg-indigo-950/50 dark:text-indigo-300",
                else:
                  "border-zinc-200 dark:border-zinc-700 text-zinc-600 dark:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-800"
              )
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <%= if @people == [] do %>
        <p id="usage-no-people" class="py-6 text-xs text-zinc-500 text-center">
          {gettext("No questions in this period.")}
        </p>
      <% else %>
        <div class="overflow-x-auto">
          <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400 tabular-nums">
            <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
              <tr>
                <th class="py-2.5 px-2 w-8">#</th>
                <th class="py-2.5 px-2">{gettext("Person")}</th>
                <th class="py-2.5 px-2 text-right">{gettext("Questions")}</th>
                <th class="py-2.5 px-2 text-right">{gettext("Tokens")}</th>
                <th class="py-2.5 px-2 text-right">{gettext("Solved rate")}</th>
                <th :if={@scope == :platform} class="py-2.5 px-2">{gettext("Desks")}</th>
                <th class="py-2.5 px-2 text-right">{gettext("Last question")}</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
              <tr
                :for={{person, rank} <- Enum.with_index(@people, 1)}
                id={"usage-person-#{person.user_id}"}
                class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition align-top"
              >
                <td class="py-2.5 px-2 text-zinc-400">{rank}</td>
                <td class="py-2.5 px-2">
                  <.person person={person} />
                </td>
                <td class="py-2.5 px-2 text-right font-medium text-zinc-900 dark:text-zinc-100">
                  {num(person.questions)}
                </td>
                <td class="py-2.5 px-2 text-right">{num(person.tokens)}</td>
                <td class="py-2.5 px-2 text-right">
                  {if person.solved_rate, do: "#{person.solved_rate}%", else: "-"}
                </td>
                <td :if={@scope == :platform} class="py-2.5 px-2">
                  <details id={"usage-desks-#{person.user_id}"} class="group">
                    <summary class="list-none cursor-pointer inline-flex items-center gap-1 text-indigo-600 dark:text-indigo-400 hover:underline [&::-webkit-details-marker]:hidden">
                      {gettext("%{count} desk(s)", count: length(person.desks))}
                      <.icon
                        name="hero-chevron-down"
                        class="w-3 h-3 transition group-open:rotate-180"
                      />
                    </summary>
                    <ul class="mt-1.5 space-y-0.5 text-[11px]">
                      <li
                        :for={desk <- person.desks}
                        class="flex justify-between gap-3 whitespace-nowrap"
                      >
                        <span class="text-zinc-700 dark:text-zinc-300">{desk.app.name}</span>
                        <span class="text-zinc-500">
                          {gettext("%{questions} questions · %{tokens} tokens",
                            questions: num(desk.questions),
                            tokens: num(desk.tokens)
                          )}
                        </span>
                      </li>
                    </ul>
                  </details>
                </td>
                <td class="py-2.5 px-2 text-right font-mono text-[11px] whitespace-nowrap">
                  {AskDrive.Clock.format(person.last_at, "%Y-%m-%d %H:%M")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  attr :person, :map, required: true

  defp person(assigns) do
    ~H"""
    <%= case @person.kind do %>
      <% :user -> %>
        <p class="font-medium text-zinc-900 dark:text-zinc-100">{@person.name}</p>
        <p :if={@person.name != @person.email} class="text-[11px] text-zinc-500">
          {@person.email}
        </p>
      <% :guest -> %>
        <p class="font-medium text-zinc-700 dark:text-zinc-300">
          {gettext("Guest (without signing in)")}
        </p>
      <% :deleted -> %>
        <p class="text-zinc-500">{gettext("A deleted user")}</p>
    <% end %>
    """
  end

  attr :questions, :list, required: true

  defp frequent(assigns) do
    ~H"""
    <div
      id="usage-frequent"
      class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
    >
      <div>
        <h3 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
          <.icon name="hero-fire" class="w-5 h-5 text-amber-500" />
          {gettext("Frequently asked questions")}
        </h3>
        <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
          {gettext(
            "New questions (not follow-ups) asked at least %{count} times, by the same wording (spaces, punctuation and full-width letters aside). Who asked is not shown. Those mostly left unsolved are worth a document or a clearer one.",
            count: Usage.frequent_min()
          )}
        </p>
      </div>

      <%= if @questions == [] do %>
        <p id="usage-no-frequent" class="py-6 text-xs text-zinc-500 text-center">
          {gettext("No question was asked more than once in this period.")}
        </p>
      <% else %>
        <ul
          id="usage-frequent-rows"
          class="divide-y divide-zinc-200/60 dark:divide-zinc-800 border-t border-zinc-200/60 dark:border-zinc-800"
        >
          <li
            :for={{q, i} <- Enum.with_index(@questions, 1)}
            id={"usage-frequent-#{i}"}
            class="py-3 flex flex-col sm:flex-row sm:items-center gap-x-4 gap-y-1 text-xs"
          >
            <p class="flex-1 min-w-0 text-zinc-900 dark:text-zinc-100 break-words">
              {q.question}
            </p>
            <div class="flex items-center gap-3 shrink-0 tabular-nums text-zinc-500">
              <span class="font-semibold text-zinc-900 dark:text-zinc-100">
                {gettext("%{count} times", count: num(q.count))}
              </span>
              <span>{gettext("solved %{rate}%", rate: rate(q))}</span>
              <span
                :if={rate(q) < 50}
                id={"usage-frequent-#{i}-unsolved"}
                class="px-2 py-0.5 rounded-full bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 text-[10px] font-medium"
              >
                {gettext("Mostly unsolved")}
              </span>
              <span class="font-mono text-[11px]">
                {AskDrive.Clock.format(q.last_at, "%Y-%m-%d")}
              </span>
            </div>
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  defp rate(%{count: count, solved: solved}) when count > 0, do: round(solved / count * 100)
  defp rate(_), do: 0
end
