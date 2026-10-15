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
          {gettext("API gateway (entry point for Google sign-in)")}
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
          {if @on?, do: gettext("On (via the gateway only)"), else: gettext("Off")}
        </span>
      </div>
      <p class="text-xs text-zinc-500 leading-relaxed">
        {gettext(
          "Lets only people who have passed Google Workspace sign-in at an API gateway (such as Sakura Cloud's) reach AskDrive. The gateway adds a secret header ("
        )}<code class="font-mono">X-Apigw-Secret</code>{gettext(
          ") to every request it forwards. Once the same value is set here, direct access without the header is refused with 403 (including the sign-in screen and the connection that updates the screen). For requests from the gateway, the user's IP (X-Forwarded-For) is trusted, and links, redirects and the Google sign-in redirect URI are built from the “Public URL” below."
        )}
      </p>
      <p class="text-xs text-zinc-600 dark:text-zinc-400">
        {gettext("This screen's connection:")}
        <span id="gateway-this-connection" class="font-medium">
          {if @via_gateway,
            do: gettext("Via the gateway (secret header present)"),
            else: gettext("Direct (%{ip})", ip: @peer_ip || gettext("unknown"))}
        </span>
      </p>

      <AskDriveWeb.FeatureToggle.toggle
        id="toggle-gateway"
        feature="gateway"
        on={@on?}
        label={gettext("API gateway check")}
        hint={
          gettext(
            "Can be turned on once the secret header value and public URL are saved. From then on, direct access without the header is refused."
          )
        }
        confirm_on={
          gettext(
            "Turn on the API gateway check. Connections that don't go through the gateway (except from the server itself and allowed IPs) will be refused immediately. Continue?"
          )
        }
      />

      <form id="gateway-form" phx-submit="save_gateway" class="space-y-3">
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs">
          <label class="space-y-1">
            <span class="block font-medium">
              {if @gw.secret,
                do: gettext("Secret header value (set; enter only to change it; 16+ characters)"),
                else: gettext("Secret header value (not set; 16+ characters)")}
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
            <span class="block font-medium">{gettext("Public URL (the URL users open)")}</span>
            <input
              type="url"
              name="gateway[public_url]"
              value={@gw.public_url}
              placeholder={gettext("e.g. https://app.example.com")}
              class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
            />
          </label>
          <label class="space-y-1 sm:col-span-2">
            <span class="block font-medium">
              {gettext(
                "IPs allowed to connect directly, bypassing the gateway (optional; comma-separated, ranges like 192.168.0.0/16; leave empty to allow none)"
              )}
            </span>
            <input
              type="text"
              name="gateway[direct_ranges]"
              value={Enum.join(@gw.direct_ranges, ", ")}
              placeholder={
                gettext(
                  "e.g. 192.168.0.0/16 (to use it directly from the office LAN during migration)"
                )
              }
              class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
            />
          </label>
        </div>
        <p class="text-[11px] text-zinc-400 leading-relaxed">
          {gettext(
            "“Save” only saves the values; the check is turned on and off with the switch above. It can be turned on only while this screen is opened via the gateway (with the same secret value), from the server itself (localhost) or from an IP allowed direct access (so you don't lock yourself out). The server itself can always connect directly. If you are locked out, run"
          )}
          <code class="font-mono">./app.sh network gateway-off</code>
          {gettext(
            "on the server (takes effect without a restart). Don't send the secret value by email; receive it in a secure way."
          )}
        </p>
        <div class="flex justify-end">
          <button
            type="submit"
            id="save-gateway-btn"
            class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
          >
            {gettext("Save")}
          </button>
        </div>
      </form>
    </div>
    """
  end
end
