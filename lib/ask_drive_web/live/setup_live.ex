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
          <h1 class="font-bold text-2xl text-zinc-900 dark:text-zinc-100">
            {gettext("AskDrive Initial Setup")}
          </h1>
          <p class="text-sm text-zinc-500 mt-1 leading-relaxed">
            {gettext(
              "Set up your administrator password and organization settings. This screen will remain until setup is finished."
            )}
          </p>
        </div>

        <form
          id="setup-form"
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

          <.setup_field
            name="password"
            type="password"
            label={gettext("2. Administrator Password")}
            errors={@errors}
            autocomplete="new-password"
          >
            {gettext("Required when elevating to administrator. Minimum %{length} characters.",
              length: AskDrive.Accounts.AdminAccess.min_password_length()
            )}
          </.setup_field>
          <.setup_field
            name="password_confirmation"
            type="password"
            label={gettext("Administrator Password (Confirm)")}
            errors={@errors}
            autocomplete="new-password"
          />

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
            placeholder="name@company.com"
          >
            {gettext("Email addresses for initial platform administrators (comma-separated).")}
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
