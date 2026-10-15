defmodule AskDriveWeb.AcmePanel do
  @moduledoc """
  The platform admin screen's Let's Encrypt section, inside the HTTPS card (spec F-1009 –
  F-1012): the settings (host name, Value-Domain zone and API key, contact, staging), the
  last result and the next renewal, a DNS connection test, 「今すぐ取得」, and the steps of
  the run in progress. Events go to `AskDriveWeb.AdminLive`.
  """
  use AskDriveWeb, :html

  alias AskDrive.ACME.Renewal

  attr :setting, :map, required: true
  attr :form, :any, required: true
  attr :status, :map, default: nil
  attr :dns_test, :any, default: nil

  def acme_section(assigns) do
    assigns =
      assigns
      |> assign(:running?, match?(%{running?: true}, assigns.status))
      |> assign(:configured?, Renewal.configured?(assigns.setting))
      |> assign(:ready?, Renewal.ready?(assigns.setting))
      |> assign(:renew_after, Renewal.renew_after())

    ~H"""
    <div id="acme-settings" class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3">
      <div>
        <h3 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200 flex items-center gap-2">
          <.icon name="hero-shield-check" class="w-4 h-4 text-emerald-600" />
          {gettext("Let's Encrypt (automatic certificate issuance and renewal)")}
        </h3>
        <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
          {gettext(
            "Gets a certificate trusted by browsers and the API gateway from Let's Encrypt for free, and renews it automatically as it nears expiry. Ownership is proven with a DNS TXT record (DNS-01), so this server can stay inside the LAN. The TXT record is added through the Value-Domain DNS API and deleted as soon as the check is done. Renewal is tried once, during the nightly batch window, on the first night when less than a third of the validity period is left (30 days for a 90-day certificate); if it fails, it is tried again on the following nights. The result is posted to Google Chat (if an update notification destination is set)."
          )}
        </p>
      </div>

      <div id="acme-state" class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
        <div>
          <span class="text-zinc-400 block">{gettext("Status")}</span>
          <span class={[
            "font-medium",
            cond do
              @running? -> "text-indigo-700 dark:text-indigo-300"
              @configured? -> "text-emerald-700 dark:text-emerald-300"
              true -> "text-zinc-500"
            end
          ]}>
            {cond do
              @running? -> gettext("Obtaining…")
              @configured? -> gettext("On")
              @setting.acme_enabled -> gettext("Settings incomplete")
              true -> gettext("Automatic renewal is off")
            end}
          </span>
        </div>
        <div>
          <span class="text-zinc-400 block">{gettext("Last run")}</span>
          <span class="font-mono">{AskDrive.Clock.format(@setting.acme_checked_at, "%Y-%m-%d %H:%M")}</span>
        </div>
        <div>
          <span class="text-zinc-400 block">{gettext("Next renewal")}</span>
          <span class="font-mono">
            {if @renew_after,
              do:
                gettext("The night of %{date} or later",
                  date: AskDrive.Clock.format(@renew_after, "%Y-%m-%d")
                ),
              else: gettext("— (shown once a Let's Encrypt certificate is obtained)")}
          </span>
        </div>
      </div>

      <p
        :if={@setting.acme_last_result && not @running?}
        id="acme-last-result"
        class={[
          "text-xs rounded-lg border px-3 py-2 break-all",
          if(@setting.acme_last_ok,
            do:
              "border-emerald-200 bg-emerald-50 text-emerald-800 dark:bg-emerald-950/40 dark:border-emerald-900 dark:text-emerald-200",
            else:
              "border-red-200 bg-red-50 text-red-700 dark:bg-red-950/40 dark:border-red-900 dark:text-red-300"
          )
        ]}
      >
        {if @setting.acme_last_ok,
          do: gettext("Succeeded: %{result}", result: @setting.acme_last_result),
          else: gettext("Failed: %{result}", result: @setting.acme_last_result)}
      </p>

      <div
        :if={@status && @status.log != []}
        id="acme-log"
        class="rounded-lg bg-zinc-950 text-zinc-100 font-mono text-[11px] leading-relaxed px-3 py-2 max-h-48 overflow-y-auto"
      >
        <p :for={line <- Enum.reverse(@status.log)} class="whitespace-pre-wrap break-all">{line}</p>
      </div>

      <AskDriveWeb.FeatureToggle.toggle
        id="toggle-acme"
        feature="acme"
        on={@setting.acme_enabled == true}
        label={gettext("Nightly automatic renewal")}
        hint={
          gettext(
            "Can be turned on once the host name, domain and API key are saved. “Obtain now” works even while this is off (try it with staging first)."
          )
        }
      />

      <.form for={@form} id="acme-form" phx-submit="save_acme" class="space-y-3">
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <.input
            field={@form[:acme_hostname]}
            type="text"
            label={gettext("Certificate host name")}
            placeholder={gettext("e.g. ask.example.com")}
          />
          <.input
            field={@form[:acme_dns_zone]}
            type="text"
            label={gettext("Domain managed at Value-Domain")}
            placeholder={gettext("e.g. example.com")}
          />
          <.input
            field={@form[:valuedomain_api_key]}
            type="password"
            value=""
            autocomplete="off"
            label={
              if present?(@setting.valuedomain_api_key),
                do: gettext("Value-Domain API key (set; enter only to change it)"),
                else: gettext("Value-Domain API key (not set)")
            }
          />
          <.input
            field={@form[:acme_email]}
            type="email"
            label={gettext("Contact email (optional)")}
            placeholder={gettext("Let's Encrypt sends expiry warnings and the like here")}
          />
        </div>
        <.input
          field={@form[:acme_staging]}
          type="checkbox"
          label={
            gettext(
              "Get a test (staging) certificate (browsers will show a warning; for checking the settings)"
            )
          }
        />
        <p class="text-[11px] text-zinc-500 leading-relaxed">
          {gettext(
            "“Save” only saves the values; automatic renewal is turned on and off with the switch above. Issue the API key in Value-Domain's “API” settings; it is stored encrypted. Value-Domain's DNS API rewrites all of a domain's records at once, so before every change the whole record set is saved on the server in"
          )}
          <code class="font-mono">ssl/acme/dns_backup/</code>
          {gettext(
            "and after the change it is read back to confirm that nothing but the TXT record changed. The first time, make sure a “test” certificate can be obtained before switching to a production one (production has a limit on failed attempts)."
          )}
        </p>
        <div class="flex flex-wrap items-center gap-2">
          <button
            type="submit"
            id="save-acme-btn"
            class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium transition"
          >
            {gettext("Save")}
          </button>
          <button
            type="button"
            id="test-acme-dns-btn"
            phx-click="test_acme_dns"
            disabled={
              not present?(@setting.valuedomain_api_key) or not present?(@setting.acme_dns_zone)
            }
            class="px-4 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium transition disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {gettext("Test DNS connection (changes nothing)")}
          </button>
          <button
            type="button"
            id="run-acme-btn"
            phx-click="run_acme"
            disabled={not @ready? or @running?}
            data-confirm={
              gettext(
                "Get a certificate from Let's Encrypt and restart HTTPS to apply it. A temporary TXT record is added to DNS and deleted after the check. Continue?"
              )
            }
            class="px-4 py-2 rounded-lg border border-emerald-300 text-emerald-800 dark:text-emerald-200 dark:border-emerald-800 hover:bg-emerald-50 dark:hover:bg-emerald-950/40 text-xs font-medium transition disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {if @running?, do: gettext("Obtaining…"), else: gettext("Obtain now")}
          </button>
        </div>
      </.form>

      <%= case @dns_test do %>
        <% :running -> %>
          <p id="acme-dns-test" class="text-xs text-zinc-500">
            {gettext("Connecting to Value-Domain…")}
          </p>
        <% {:ok, count} -> %>
          <p id="acme-dns-test" class="text-xs text-emerald-700 dark:text-emerald-300">
            {gettext("Connected (found %{count} records for %{zone}; nothing was changed).",
              count: count,
              zone: @setting.acme_dns_zone
            )}
          </p>
        <% {:error, message} -> %>
          <p id="acme-dns-test" class="text-xs text-red-600">{message}</p>
        <% _ -> %>
      <% end %>
    </div>
    """
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
