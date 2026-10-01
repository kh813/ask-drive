defmodule AskDriveWeb.SetupLive do
  @moduledoc """
  First-access setup (spec 6.12): setup code, account type (Google Workspace domain vs Personal Gmail),
  the first app's name and the platform administrators. See `AskDrive.Setup`.
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
       |> assign(:account_type, "workspace")
       |> assign(:values, %{
         "app_name" => AskDrive.Apps.primary().name,
         "account_type" => "workspace",
         "domain" => "",
         "admin_emails" => ""
       })}
    else
      {:ok, push_navigate(socket, to: "/")}
    end
  end

  @impl true
  def handle_event("change_account_type", %{"type" => type}, socket)
      when type in ["workspace", "personal"] do
    values = Map.put(socket.assigns.values, "account_type", type)
    {:noreply, socket |> assign(:account_type, type) |> assign(:values, values)}
  end

  def handle_event("form_change", params, socket) do
    account_type = params["account_type"] || socket.assigns.account_type
    values = Map.merge(socket.assigns.values, params)
    {:noreply, socket |> assign(:account_type, account_type) |> assign(:values, values)}
  end

  def handle_event("setup", params, socket) do
    account_type = params["account_type"] || socket.assigns.account_type || "workspace"
    params = Map.put(params, "account_type", account_type)

    case Setup.complete(params) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "初回セットアップが完了しました。次に、窓口の Google Drive と AI を設定してください。"
         )
         |> redirect(to: "/admin?tab=apps")}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:errors, errors)
         |> assign(:account_type, account_type)
         |> assign(
           :values,
           Map.take(params, ["account_type", "domain", "app_name", "admin_emails"])
         )}
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
          <h1 class="font-bold text-2xl text-zinc-900 dark:text-zinc-100">
            {gettext("AskDrive Initial Setup")}
          </h1>
          <p class="text-sm text-zinc-500 mt-1 leading-relaxed">
            {gettext(
              "Set up your organization settings and administrators. This screen will remain until setup is finished."
            )}
          </p>
        </div>

        <form
          id="setup-form"
          phx-change="form_change"
          phx-submit="setup"
          class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-5"
        >
          <.setup_field
            name="code"
            label={gettext("1. Setup Code")}
            errors={@errors}
            placeholder="XXXX-XXXX-XXXX"
            autocomplete="off"
          >
            {gettext("Enter the setup code found on the server.")}
            <code class="font-mono">./app.sh status</code>
          </.setup_field>

          <div class="space-y-2">
            <span class="block text-sm font-medium text-zinc-800 dark:text-zinc-200">
              {gettext("2. Account & Usage Type")}
            </span>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label class={[
                "flex flex-col p-3 rounded-xl border cursor-pointer transition text-left",
                if(@account_type == "workspace",
                  do:
                    "border-indigo-600 bg-indigo-50/50 dark:bg-indigo-950/20 ring-1 ring-indigo-600",
                  else:
                    "border-zinc-200 dark:border-zinc-800 hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
                )
              ]}>
                <div class="flex items-center gap-2">
                  <input
                    type="radio"
                    name="account_type"
                    value="workspace"
                    checked={@account_type == "workspace"}
                    class="text-indigo-600 focus:ring-indigo-500"
                  />
                  <span class="text-xs font-semibold text-zinc-900 dark:text-zinc-100">
                    {gettext("Google Workspace (Company/Org)")}
                  </span>
                </div>
                <span class="text-[11px] text-zinc-500 mt-1 pl-6">
                  {gettext("Restrict access to your organization domain (e.g. company.com).")}
                </span>
              </label>

              <label class={[
                "flex flex-col p-3 rounded-xl border cursor-pointer transition text-left",
                if(@account_type == "personal",
                  do:
                    "border-indigo-600 bg-indigo-50/50 dark:bg-indigo-950/20 ring-1 ring-indigo-600",
                  else:
                    "border-zinc-200 dark:border-zinc-800 hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
                )
              ]}>
                <div class="flex items-center gap-2">
                  <input
                    type="radio"
                    name="account_type"
                    value="personal"
                    checked={@account_type == "personal"}
                    class="text-indigo-600 focus:ring-indigo-500"
                  />
                  <span class="text-xs font-semibold text-zinc-900 dark:text-zinc-100">
                    {gettext("Personal Account / No Domain Restriction")}
                  </span>
                </div>
                <span class="text-[11px] text-zinc-500 mt-1 pl-6">
                  {gettext("Use personal Gmail (@gmail.com) or allow any Google account.")}
                </span>
              </label>
            </div>
          </div>

          <%= if @account_type == "workspace" do %>
            <.setup_field
              name="domain"
              label={gettext("3. Organization Google Workspace Domain")}
              errors={@errors}
              value={@values["domain"]}
              placeholder="company.com"
            >
              {gettext(
                "Only accounts from this domain will be accepted for Google Login (SSO) and Google Drive."
              )}
            </.setup_field>
          <% else %>
            <div class="p-3.5 rounded-xl bg-zinc-50 dark:bg-zinc-800/40 border border-zinc-200/70 dark:border-zinc-800 text-xs text-zinc-600 dark:text-zinc-400 space-y-1">
              <p class="font-medium text-zinc-800 dark:text-zinc-200">
                {gettext("Domain restriction is disabled")}
              </p>
              <p class="text-[11px] leading-relaxed">
                {gettext(
                  "Any Google account (including personal @gmail.com) can be used. You can later restrict domains in Platform Settings if needed."
                )}
              </p>
            </div>
          <% end %>

          <.setup_field
            name="app_name"
            label={gettext("4. First Desk Name")}
            errors={@errors}
            value={@values["app_name"]}
          >
            {gettext(
              "Will appear in the chat header as \"AskDrive for (this name)\". Can be changed later."
            )}
          </.setup_field>

          <.setup_field
            name="admin_emails"
            label={gettext("5. Platform Administrator Email Addresses")}
            errors={@errors}
            value={@values["admin_emails"]}
            placeholder={
              if(@account_type == "workspace",
                do: "name@company.com",
                else: "user@gmail.com"
              )
            }
          >
            {gettext(
              "Email addresses for initial platform administrators (comma-separated). They enter Platform Admin with their own account — no shared password."
            )}
          </.setup_field>

          <button
            type="submit"
            id="setup-submit"
            class="w-full px-4 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-sm shadow-sm"
          >
            {gettext("Complete Setup")}
          </button>
          <p class="text-[11px] text-zinc-500">
            {gettext("OAuth Client ID / Secret can be configured later in Platform Settings.")}
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
