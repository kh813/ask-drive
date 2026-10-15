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

  alias AskDrive.Accounts.{AdminAccess, AdminElevationLog, AppAdminAccess}
  alias AskDrive.Batch.{ItemLog, Progress, Scheduler}
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.Drive.{Client, ServiceAccount}
  alias AskDrive.LLM
  alias AskDrive.QA.QAPair
  alias AskDrive.{Accounts, ChatSummary, Documents, HealthCheck, QA, Repo, Settings, Vector}
  alias AskDrive.Runtime.Mode

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Refresh status periodically
      :timer.send_interval(5000, self(), :tick)
      # Ollama model download progress (spec F-827)
      Phoenix.PubSub.subscribe(AskDrive.PubSub, AskDrive.LLM.OllamaModels.topic())
      # a Drive authorization finished in Google's window (spec F-352)
      if app = socket.assigns[:app],
        do: Phoenix.PubSub.subscribe(AskDrive.PubSub, "drive_auth:" <> app.slug)

      # an update's progress and log (F-1502), on the platform screen
      if socket.assigns.live_action == :platform,
        do: Phoenix.PubSub.subscribe(AskDrive.PubSub, AskDrive.Updates.Server.topic())

      # a Let's Encrypt run's steps (F-1012), on the platform screen
      if socket.assigns.live_action == :platform,
        do: Phoenix.PubSub.subscribe(AskDrive.PubSub, AskDrive.ACME.Renewal.topic())

      # installing Ollama from the platform screen (F-837)
      if socket.assigns.live_action == :platform,
        do: Phoenix.PubSub.subscribe(AskDrive.PubSub, AskDrive.LLM.OllamaInstaller.topic())
    end

    setting = Settings.get_setting!()
    form = to_form(Settings.change_setting(setting))

    # Own SSL certificate upload (spec 6.10): PEM files only. accept: :any because .pem/.key
    # have no registered MIME type (a list of those extensions raises in allow_upload and
    # takes the whole admin page down); the contents are checked by AskDrive.SSL.validate.
    socket =
      socket
      |> allow_upload(:ssl_cert, accept: :any, max_entries: 1, max_file_size: 200_000)
      |> allow_upload(:ssl_key, accept: :any, max_entries: 1, max_file_size: 200_000)
      |> allow_upload(:ssl_chain, accept: :any, max_entries: 1, max_file_size: 500_000)
      # Google Secure LDAP client certificate / key and an optional CA (spec 6.13)
      |> allow_upload(:ldap_cert, accept: :any, max_entries: 1, max_file_size: 200_000)
      |> allow_upload(:ldap_key, accept: :any, max_entries: 1, max_file_size: 200_000)
      |> allow_upload(:ldap_ca, accept: :any, max_entries: 1, max_file_size: 500_000)
      |> assign(:ldap_test, nil)
      |> assign(:ac, %{})
      |> assign(:peer_ip, peer_ip(socket))
      |> assign(:gateway_header, gateway_header(socket))
      |> assign(:gateway_settings, AskDrive.Gateway.settings())
      |> assign(:peer_cert, peer_cert(socket))
      |> assign(:issued_cert, nil)
      |> assign(:drive_sync_test, nil)
      |> assign(:ldap_pending, %{})
      |> assign(:ssl_check, nil)

    # One LiveView, two scopes (spec 6.11): /admin administers the platform (apps, users,
    # SSL, Ollama, the nightly window); /:app/admin administers one app (its batch, documents,
    # questions, Drive and AI settings). AppScope has already selected the app's database.
    scope = socket.assigns.live_action || :app

    socket =
      socket
      |> assign(:scope, scope)
      |> assign_new(:app, fn -> nil end)
      |> assign_new(:apps, fn -> AskDrive.Apps.list() end)
      |> assign_new(:base_path, fn -> "" end)
      |> assign(:app_form, blank_app_form())
      |> assign(:show_new_app, false)
      |> assign(:last_created_app, nil)
      |> prefill_enable_auth_admins()

    {:ok,
     socket
     |> assign(:current_tab, default_tab(scope))
     |> assign(:setting, setting)
     |> assign(:ldap_form, ldap_form(setting))
     |> assign(:form, form)
     |> assign(:llm_view, llm_view(setting))
     |> assign(:trigger_batch_loading, false)
     |> assign(:connection_test, %{})
     |> assign(:service_account_test, nil)
     |> assign(:access_password_form, to_form(%{}, as: :access_password))
     |> assign(:update_status, if(scope == :platform, do: AskDrive.Updates.status()))
     |> assign(:update_latest, nil)
     |> assign(:update_checking, false)
     |> assign(:notify_test, nil)
     |> assign(:acme_form, acme_form(setting))
     |> assign(:acme_status, if(scope == :platform, do: AskDrive.ACME.Renewal.status()))
     |> assign(:acme_dns_test, nil)
     |> assign(:cloud_models, %{})
     |> maybe_load_cloud_models()
     |> assign(:ollama_starting, false)
     |> assign_ollama_runtime()
     |> load_dashboard_data()}
  end

  # The platform screen's Ollama card (F-837): installed, running, which desks need it, and an
  # install in progress. Asks Ollama (a short request), so only on the platform screen.
  defp assign_ollama_runtime(socket) do
    if socket.assigns.scope == :platform do
      socket
      |> assign(:ollama_runtime, AskDrive.LLM.OllamaServer.status())
      |> assign(:ollama_needed, AskDrive.LLM.OllamaModels.required_all())
      |> assign(:ollama_overview, AskDrive.LLM.OllamaModels.overview())
      |> assign(:ollama_pulls, AskDrive.LLM.OllamaModels.pulls())
      |> assign(:ollama_install, AskDrive.LLM.OllamaInstaller.status())
    else
      socket
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tabs = Enum.map(tabs(socket.assigns.scope), &elem(&1, 0))
    tab = if params["tab"] in tabs, do: params["tab"], else: default_tab(socket.assigns.scope)
    {:noreply, assign(socket, :current_tab, tab)}
  end

  defp tabs(:platform),
    do: [
      {"apps", gettext("Desks (apps)")},
      {"users", gettext("Users")},
      {"audit", gettext("Elevation log")},
      {"metrics", gettext("API usage & logs")},
      {"settings", gettext("Platform settings")},
      {"update", gettext("Updates")}
    ]

  defp tabs(:app),
    do: [
      {"overview", gettext("Overview & batch status")},
      {"questions", gettext("Unanswered & resolved questions")},
      {"documents", gettext("Documents")},
      {"metrics", gettext("API usage & logs")},
      {"settings", gettext("Settings")}
    ]

  defp default_tab(scope), do: scope |> tabs() |> hd() |> elem(0)

  # --- Updating from the admin screen (F-1501–F-1506), platform scope only ---

  @impl true
  def handle_info({:acme_status, status}, socket) do
    # a run that just finished has written its result on the setting row
    socket =
      if status.running?,
        do: socket,
        else: assign(socket, :setting, Settings.get_setting!())

    {:noreply, assign(socket, :acme_status, status)}
  end

  def handle_info({:update_status, status}, socket),
    do: {:noreply, assign(socket, :update_status, status)}

  # an Ollama install's progress (F-837); once done, AskDrive starts it: look again shortly
  def handle_info({:ollama_install, status}, socket) do
    if status.status == :done and socket.assigns.ollama_install.status == :installing do
      Process.send_after(self(), :refresh_ollama, 3_000)
      Process.send_after(self(), :refresh_ollama, 15_000)
    end

    {:noreply, assign(socket, :ollama_install, status)}
  end

  def handle_info(:refresh_ollama, socket), do: {:noreply, assign_ollama_runtime(socket)}

  def handle_info({:update_log, line}, socket) do
    {:noreply,
     Phoenix.Component.update(socket, :update_status, fn
       %{log: log} = status -> %{status | log: Enum.take(log ++ [line], -400)}
       other -> other
     end)}
  end

  def handle_info({:update_checked, result}, socket) do
    {:noreply,
     socket
     |> assign(:update_latest, result)
     |> assign(:update_checking, false)
     |> assign(:setting, Settings.get_setting!())}
  end

  def handle_info({:ollama_pulls, pulls}, socket) do
    finished? = Enum.any?(pulls, fn {_m, p} -> p.status in ["done", "failed"] end)
    socket = assign(socket, :ollama_pulls, pulls)

    # a finished download changes what's installed (and what a desk can choose)
    socket =
      cond do
        not finished? -> socket
        socket.assigns.scope == :platform -> assign_ollama_runtime(socket)
        true -> assign_ollama_models(socket)
      end

    {:noreply, socket}
  end

  # Google brought the authorizing window back to AskDrive and the tokens were saved there
  def handle_info({:drive_connected, email}, socket) do
    {:noreply,
     socket
     |> assign(:drive_auth_code, "")
     |> assign(:drive_auth, nil)
     |> assign(:drive_auth_result, {:ok, gettext("Connected %{email}.", email: email)})
     |> put_flash(
       :info,
       gettext(
         "Connected the Google Drive sync account (%{email}). Check it with \"Test sync\".",
         email: email
       )
     )
     |> load_dashboard_data()}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, load_dashboard_data(socket)}
  end

  # --- Apps (platform scope, spec 6.11) ---------------------------------------

  @impl true
  def handle_event("toggle_new_app", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_app, not socket.assigns.show_new_app)
     |> assign(:last_created_app, nil)
     |> assign(:app_form, blank_app_form())}
  end

  # Live feedback while typing: format, reserved words and slugs already taken
  def handle_event("validate_app", %{"app" => params}, socket) do
    changeset =
      %AskDrive.Apps.App{}
      |> AskDrive.Apps.App.changeset(params)
      |> then(fn cs ->
        slug = Ecto.Changeset.get_field(cs, :slug)

        if slug && AskDrive.Apps.get_by_slug(slug),
          do: Ecto.Changeset.add_error(cs, :slug, "is already taken"),
          else: cs
      end)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :app_form, to_form(changeset, as: :app))}
  end

  def handle_event("create_app", %{"app" => params}, socket) do
    domain = Settings.platform_setting!().allowed_domain

    # an app always has an administrator (F-1114), named at creation
    with {:ok, emails} <- parse_admin_emails(params["admin_emails"], domain),
         :ok <- check_directory(emails),
         {:ok, app} <- AskDrive.Apps.create(Map.delete(params, "admin_emails")) do
      :ok = AppAdminAccess.add_admins(socket.assigns.current_user, app, emails)
      socket |> clear_ac("new-app-admin-emails") |> create_app_done(app)
    else
      {:error, message} when is_binary(message) ->
        {:noreply,
         socket
         |> assign(
           :app_form,
           to_form(AskDrive.Apps.App.changeset(%AskDrive.Apps.App{}, params), as: :app)
         )
         |> put_flash(:error, gettext("Administrators: %{message}", message: message))}

      other ->
        create_app_result(socket, other)
    end
  end

  def handle_event(
        "update_app",
        %{"id" => id, "name" => name, "description" => description},
        socket
      ) do
    app = AskDrive.Apps.get!(String.to_integer(id))

    case AskDrive.Apps.update(app, %{name: name, description: description}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:apps, AskDrive.Apps.list())
         |> put_flash(:info, gettext("Desk updated."))
         |> load_dashboard_data()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Enter a desk name."))}
    end
  end

  def handle_event("delete_app", %{"id" => id}, socket) do
    app = AskDrive.Apps.get!(String.to_integer(id))

    case AskDrive.Apps.delete(app) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:apps, AskDrive.Apps.list())
         |> put_flash(
           :info,
           gettext("Desk \"%{name}\" deleted (its database file is kept under another name).",
             name: app.name
           )
         )
         |> load_dashboard_data()}

      {:error, :primary} ->
        {:noreply, put_flash(socket, :error, gettext("The first desk can't be deleted."))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not delete: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_event("ssl_upload_change", _params, socket), do: {:noreply, socket}

  # The LDAP form keeps what is being typed (a re-render must not reset it) and fills in the
  # Google defaults for what is blank (spec F-1306).
  def handle_event("ldap_change", %{"ldap" => params}, socket) do
    {:noreply, assign(socket, :ldap_form, autofill_ldap(params, socket.assigns.setting))}
  end

  def handle_event("ldap_change", _params, socket), do: {:noreply, socket}

  # "保存" and "接続テスト" submit the same form (the button pressed arrives as "op"):
  # the test runs on the form's contents, saved or not, including newly chosen files.
  def handle_event("save_ldap", params, socket) do
    socket = take_ldap_uploads(socket)
    # whether LDAP sign-in is on is its switch's business (F-206), not the form's
    form =
      params
      |> Map.get("ldap", %{})
      |> Map.put("ldap_enabled", to_string(socket.assigns.setting.ldap_enabled == true))
      |> autofill_ldap(socket.assigns.setting)

    uploads = Map.new(socket.assigns.ldap_pending, fn {kind, {_name, pem}} -> {kind, pem} end)
    socket = assign(socket, :ldap_form, form)

    if params["op"] == "test" do
      result =
        case Settings.preview_ldap(socket.assigns.setting, form, uploads) do
          {:ok, preview} -> AskDrive.Ldap.test_connection(preview)
          {:error, changeset} -> {:error, changeset_messages(changeset)}
        end

      {:noreply, assign(socket, :ldap_test, result)}
    else
      case Settings.update_ldap(socket.assigns.setting, form, uploads) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:setting, updated)
           |> assign_settings_form(updated)
           |> assign(:ldap_form, ldap_form(updated))
           |> assign(:ldap_pending, %{})
           |> put_flash(:info, gettext("LDAP sign-in settings saved."))}

        {:error, changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not save: %{errors}", errors: changeset_messages(changeset))
           )}
      end
    end
  end

  # Required login (spec F-1308). Switching it on from the guest (POC) session would leave
  # nobody able to administer unless someone can sign in and elevate, so it needs a way to
  # sign in (LDAP or Google), the administrator password, and an administrator account.
  def handle_event("enable_auth", %{"admin_email" => text}, socket) do
    setting = Settings.platform_setting!()

    parsed =
      with {:ok, emails} <- parse_admin_emails(text, setting.allowed_domain),
           :ok <- check_directory(emails),
           do: {:ok, emails}

    problem =
      cond do
        elem(AskDriveWeb.UserAuth.auth_mode(), 1) == :env ->
          gettext(
            "It is fixed by the environment variable ASK_DRIVE_DISABLE_AUTH. Remove that line from .env.prod and restart."
          )

        not (AskDrive.Ldap.enabled?(setting) or AskDrive.Drive.OAuth.login_enabled?()) ->
          gettext(
            "There is no way to sign in. First set up \"Sign in with Google Secure LDAP\" or Google login (OAuth)."
          )

        match?({:error, _}, parsed) ->
          elem(parsed, 1)

        true ->
          nil
      end

    if problem do
      {:noreply, put_flash(socket, :error, problem)}
    else
      {:ok, emails} = parsed
      Enum.each(emails, fn email -> {:ok, _} = Accounts.grant_admin(email) end)
      AppAdminAccess.ensure_primary_admins()
      {:ok, _} = Settings.set_auth_required(true)

      Logger.info(
        "AdminLive: login required switched on (administrators: #{Enum.join(emails, ", ")})"
      )

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext(
           "Login turned on. Sign in as %{emails} and verify your identity from \"Platform Admin\" to enter.",
           emails: join_list(emails)
         )
       )
       |> redirect(to: ~p"/login")}
    end
  end

  # Administrators by e-mail, including people who have never signed in (they appear in the
  # list once registered, and elevate after their first sign-in)
  def handle_event("grant_admin_emails", %{"emails" => text}, socket) do
    with {:ok, emails} <- parse_admin_emails(text, Settings.platform_setting!().allowed_domain),
         :ok <- check_directory(emails) do
      {:ok, emails}
    end
    |> case do
      {:ok, emails} ->
        Enum.each(emails, fn email -> {:ok, _} = Accounts.grant_admin(email) end)
        Logger.info("AdminLive: administrators added: #{Enum.join(emails, ", ")}")

        {:noreply,
         socket
         |> clear_ac("grant-admin-emails")
         |> put_flash(
           :info,
           gettext("%{emails} can now elevate to admin.", emails: join_list(emails))
         )
         |> load_dashboard_data()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("disable_auth", _params, socket) do
    if elem(AskDriveWeb.UserAuth.auth_mode(), 1) == :env do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext(
           "It is fixed by the environment variable ASK_DRIVE_DISABLE_AUTH. Remove that line from .env.prod and restart."
         )
       )}
    else
      {:ok, _} = Settings.set_auth_required(false)
      Logger.warning("AdminLive: login required switched off (guest mode)")

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("Login turned off (anyone can use the admin screens as a guest).")
       )
       |> load_dashboard_data()}
    end
  end

  def handle_event("unlock_login", %{"id" => id}, socket) do
    socket =
      case AskDrive.Accounts.LoginThrottle.unlock(String.to_integer(id)) do
        {:ok, lock} ->
          Logger.info("AdminLive: login lock lifted (#{lock.scope} #{lock.email || lock.ip})")
          put_flash(socket, :info, gettext("Lock lifted."))

        {:error, :not_found} ->
          put_flash(socket, :error, gettext("This lock has already been lifted."))
      end

    {:noreply, load_dashboard_data(socket)}
  end

  # Step 1: validate the uploaded PEM files (nothing is saved yet)
  def handle_event("check_ssl", params, socket) do
    read = fn name ->
      socket
      |> consume_uploaded_entries(name, fn %{path: path}, _entry -> {:ok, File.read!(path)} end)
      |> List.first()
    end

    pem = %{cert: read.(:ssl_cert), key: read.(:ssl_key), chain: read.(:ssl_chain)}
    hostname = String.trim(params["ssl_hostname"] || "")

    check =
      cond do
        is_nil(pem.cert) or is_nil(pem.key) ->
          {:error, [gettext("Choose both the certificate and the private key")]}

        true ->
          case AskDrive.SSL.validate(pem, hostname) do
            {:ok, info} -> {:ok, info, pem}
            {:error, errors} -> {:error, errors}
          end
      end

    {:noreply, assign(socket, :ssl_check, check)}
  end

  # Step 2: install the validated certificate and restart the HTTPS listener. Restarting the
  # endpoint drops this very connection, so it runs in a detached process a moment later and
  # the page reconnects on its own.
  def handle_event("apply_ssl", _params, socket) do
    case socket.assigns.ssl_check do
      {:ok, info, pem} ->
        spawn(fn ->
          Process.sleep(500)
          record_ssl_result(AskDrive.SSL.install(pem, info, "custom"))
        end)

        {:noreply,
         socket
         |> assign(:ssl_check, nil)
         |> put_flash(
           :info,
           gettext(
             "Applying the certificate. The page reconnects by itself in a few seconds (reload it if it doesn't)."
           )
         )}

      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Validate the certificate first with \"Validate\"."))}
    end
  end

  # Access only from devices with a certificate issued here (spec 6.14). "enforce" only from
  # a connection that has a valid certificate (or from the server itself), so the admin
  # can't lock themselves out; starting / stopping asking for certificates restarts the
  # HTTPS listener, detached, as for a certificate change.
  def handle_event("set_client_cert_mode", %{"mode" => mode}, socket) do
    ok_here? =
      match?({:ok, _}, AskDrive.ClientCerts.check(socket.assigns.peer_cert)) or
        socket.assigns.peer_ip in ["127.0.0.1", "::1", "::ffff:127.0.0.1"] or
        AskDrive.ClientCerts.lan?(parse_ip(socket.assigns.peer_ip))

    cond do
      mode == "enforce" and not ok_here? ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "This connection has no valid certificate and doesn't come from the office LAN. First install a certificate on this device and check, while still monitoring, that \"Certificate of this connection: valid\" is shown, or do this from the office LAN."
           )
         )}

      true ->
        {:ok, restart?} = AskDrive.ClientCerts.set_mode(mode)
        Logger.warning("AdminLive: client-certificate access mode set to #{mode}")

        if restart? do
          spawn(fn ->
            Process.sleep(700)
            AskDrive.SSL.restart_endpoint()
          end)
        end

        {:noreply,
         socket
         |> put_flash(
           :info,
           if(restart?,
             do:
               gettext(
                 "Done. Restarting the HTTPS listener (the page reconnects by itself in a few seconds; if asked to choose a certificate, choose the AskDrive one)."
               ),
             else: gettext("Done.")
           )
         )
         |> load_dashboard_data()}
    end
  end

  # the office LAN (F-1408): no certificate needed from these addresses / ranges
  def handle_event("save_client_cert_lan", %{"lan" => text}, socket) do
    case AskDrive.ClientCerts.set_lan_ranges(text) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Office LAN settings saved (effective immediately)."))
         |> load_dashboard_data()}

      {:error, bad} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Can't read these as IP addresses or ranges: %{values}",
             values: join_list(bad)
           )
         )}
    end
  end

  def handle_event("create_client_cert_group", %{"name" => name}, socket) do
    case AskDrive.ClientCerts.create_group(name) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Group \"%{name}\" added.", name: group.name))
         |> load_dashboard_data()}

      {:error, cs} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Group name %{errors}", errors: changeset_messages(cs))
         )}
    end
  end

  def handle_event("issue_client_cert", %{"group_id" => id} = params, socket) do
    group = Enum.find(socket.assigns.client_cert_groups, &(to_string(&1.id) == id))

    case AskDrive.ClientCerts.issue(group, socket.assigns.current_user.email, params) do
      {:ok, issued} ->
        token =
          AskDrive.ClientCerts.stash_download(
            issued.p12,
            issued.filename,
            group.name,
            issued.cert.serial
          )

        {:noreply,
         socket
         |> assign(:issued_cert, issued_panel(group, issued.cert, issued.password, token, false))
         |> load_dashboard_data()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # This desk's nightly batch on / off (F-344); manual runs work either way
  def handle_event("set_auto_batch", %{"on" => on}, socket) do
    on? = on == "true"
    {:ok, updated} = Settings.update_setting(socket.assigns.setting, %{auto_batch_enabled: on?})

    Logger.info(
      "AdminLive: nightly batch #{if on?, do: "enabled", else: "disabled"} for #{(socket.assigns.app && socket.assigns.app.slug) || "the primary desk"}"
    )

    {:noreply,
     socket
     |> assign(:setting, updated)
     |> assign_settings_form(updated)
     |> put_flash(
       :info,
       if(on?,
         do:
           gettext("Nightly batch turned on. It runs automatically from the next nightly window."),
         else: gettext("Nightly batch turned off (manual runs still work).")
       )
     )
     |> load_dashboard_data()}
  end

  # F-1409: the same certificate again (a lost file, another device of the same person)
  def handle_event("redownload_client_cert", %{"id" => id}, socket) do
    case AskDrive.ClientCerts.redownload(
           String.to_integer(id),
           socket.assigns.current_user.email
         ) do
      {:ok, %{token: token, password: password, cert: cert}} ->
        {:noreply,
         assign(socket, :issued_cert, issued_panel(cert.group, cert, password, token, true))}

      {:error, reason} ->
        message =
          case reason do
            :not_kept ->
              gettext(
                "This certificate was issued before re-downloads were supported, so it can't be downloaded. Issue a new one."
              )

            :revoked ->
              gettext("A revoked certificate can't be downloaded.")

            :expired ->
              gettext("An expired certificate can't be downloaded.")

            :not_found ->
              gettext("Certificate not found.")
          end

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("revoke_client_cert", %{"id" => id}, socket) do
    {:ok, _} =
      AskDrive.ClientCerts.revoke(String.to_integer(id), socket.assigns.current_user.email)

    {:noreply,
     socket |> put_flash(:info, gettext("Certificate revoked.")) |> load_dashboard_data()}
  end

  def handle_event("delete_client_cert_group", %{"group_id" => id}, socket) do
    :ok = AskDrive.ClientCerts.delete_group(String.to_integer(id))
    {:noreply, socket |> put_flash(:info, gettext("Group deleted.")) |> load_dashboard_data()}
  end

  # Ports and trusted proxies (spec F-1013). A port change restarts the endpoint, which drops
  # this very connection, so it is applied in a detached process a moment later.
  def handle_event("save_network", %{"network" => params}, socket) do
    case AskDrive.Network.validate(params) do
      {:ok, new} ->
        if AskDrive.Network.ports_changed?(new) do
          spawn(fn ->
            Process.sleep(700)
            AskDrive.Network.apply_settings(new)
          end)

          {:noreply,
           put_flash(
             socket,
             :info,
             gettext(
               "Changing the ports and restarting. In a few seconds, reopen https://<host>:%{port}/admin?tab=settings (if it can't start, the previous settings come back).",
               port: to_string(new.https_port)
             )
           )}
        else
          {:ok, _, :applied} = AskDrive.Network.apply_settings(new)

          {:noreply,
           put_flash(
             socket,
             :info,
             gettext("Reverse proxy settings saved (effective immediately).")
           )}
        end

      {:error, errors} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not save: %{errors}", errors: Enum.join(errors, "／"))
         )}
    end
  end

  # API gateway (F-1014): the values; while the check is on, only from a connection that will
  # still get in with them
  def handle_event(
        "save_gateway",
        %{"gateway" => params},
        %{assigns: %{scope: :platform}} = socket
      ) do
    with {:ok, new} <- AskDrive.Gateway.validate(params),
         :ok <- if(new.enabled, do: still_reachable(new, socket), else: :ok) do
      :ok = AskDrive.Gateway.save!(new)

      {:noreply,
       socket
       |> assign(:gateway_settings, AskDrive.Gateway.settings())
       |> put_flash(
         :info,
         if(new.enabled,
           do: gettext("API gateway settings saved (the check stays on)."),
           else:
             gettext(
               "API gateway settings saved. Turn the check on with the \"API gateway check\" switch."
             )
         )
       )}
    else
      {:error, errors} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not save: %{errors}", errors: Enum.join(errors, "／"))
         )}
    end
  end

  def handle_event("reset_self_signed", _params, socket) do
    spawn(fn ->
      Process.sleep(500)
      record_ssl_result(AskDrive.SSL.reset_to_self_signed())
    end)

    {:noreply,
     put_flash(
       socket,
       :info,
       gettext(
         "Recreating and applying the self-signed certificate. The page reconnects by itself in a few seconds."
       )
     )}
  end

  def handle_event("cancel_ssl_upload", %{"ref" => ref, "upload" => upload}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}
  end

  # Ollama's models are the platform administrator's (F-838): pulled and deleted on the
  # platform screen only
  @impl true
  def handle_event("pull_model", %{"model" => model}, %{assigns: %{scope: :platform}} = socket) do
    case String.trim(model) do
      "" ->
        {:noreply, socket}

      name ->
        AskDrive.LLM.OllamaModels.pull_async(name)

        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Started downloading %{name} (this can take a few minutes).", name: name)
         )}
    end
  end

  def handle_event("pull_missing_models", _params, %{assigns: %{scope: :platform}} = socket) do
    case socket.assigns.ollama_overview do
      {:ok, %{missing: missing}} when missing != [] ->
        pulls = AskDrive.LLM.OllamaModels.pulls()

        # a name Ollama's library doesn't have is the desk's to fix, not to pull again
        models =
          missing
          |> Enum.map(&elem(&1, 2))
          |> Enum.uniq()
          |> Enum.reject(&AskDriveWeb.OllamaPanel.not_in_library?(pulls, &1))

        Enum.each(models, &AskDrive.LLM.OllamaModels.pull_async/1)

        if models == [],
          do: {:noreply, socket},
          else:
            {:noreply,
             put_flash(
               socket,
               :info,
               gettext("Started downloading %{models}.", models: join_list(models))
             )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_model", %{"model" => model}, %{assigns: %{scope: :platform}} = socket) do
    case AskDrive.LLM.OllamaModels.delete(model) do
      :ok ->
        {:noreply,
         socket
         |> assign_ollama_runtime()
         |> put_flash(:info, gettext("Deleted %{model}.", model: model))}

      {:error, {:in_use, desks}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("%{model} can't be deleted: used by %{desks}.",
             model: model,
             desks: join_list(desks)
           )
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("%{model} couldn't be deleted: %{reason}",
             model: model,
             reason: inspect(reason)
           )
         )}
    end
  end

  @impl true
  def handle_event("select_run", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_run_id, String.to_integer(id)) |> load_dashboard_data()}
  end

  @impl true
  def handle_event("check_updates", _params, %{assigns: %{scope: :platform}} = socket) do
    lv = self()
    locale = Gettext.get_locale(AskDriveWeb.Gettext)

    Task.start(fn ->
      Gettext.put_locale(AskDriveWeb.Gettext, locale)
      send(lv, {:update_checked, AskDrive.Updates.check()})
    end)

    {:noreply, assign(socket, :update_checking, true)}
  end

  def handle_event("start_update", params, %{assigns: %{scope: :platform}} = socket) do
    user = socket.assigns.current_user
    wait = if params["wait"] == "batch_end", do: :batch_end, else: :boundary
    available = AskDrive.Updates.available_version(socket.assigns.setting)

    # already on the latest version: nothing to update to (the button is disabled too)
    result =
      if available,
        do: AskDrive.Updates.start(by: (user && user.email) || "管理者", wait: wait, to: available),
        else: {:error, :up_to_date}

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(:update_status, AskDrive.Updates.status())
         |> put_flash(
           :info,
           gettext("Update started. AskDrive restarts when the build finishes.")
         )}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, gettext("An update is already in progress."))}

      {:error, :up_to_date} ->
        {:noreply,
         put_flash(socket, :info, gettext("Running the latest version. No update available."))}
    end
  end

  def handle_event("cancel_update", _params, %{assigns: %{scope: :platform}} = socket) do
    AskDrive.Updates.cancel()
    {:noreply, assign(socket, :update_status, AskDrive.Updates.status())}
  end

  def handle_event("restart_now", _params, %{assigns: %{scope: :platform}} = socket) do
    AskDrive.Updates.restart_now()
    {:noreply, assign(socket, :update_status, AskDrive.Updates.status())}
  end

  # Let's Encrypt (spec F-1009 – F-1012), platform scope only
  def handle_event("save_acme", %{"acme" => params}, %{assigns: %{scope: :platform}} = socket) do
    case Settings.update_acme(socket.assigns.setting, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign(:acme_form, acme_form(updated))
         |> assign(:acme_dns_test, nil)
         |> put_flash(:info, gettext("Let's Encrypt settings saved."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:acme_form, to_form(changeset, as: :acme))
         |> put_flash(
           :error,
           gettext("Could not save: %{errors}", errors: changeset_messages(changeset))
         )}
    end
  end

  def handle_event("test_acme_dns", _params, %{assigns: %{scope: :platform}} = socket) do
    setting = socket.assigns.setting
    config = %{api_key: setting.valuedomain_api_key, zone: setting.acme_dns_zone}
    locale = Gettext.get_locale(AskDriveWeb.Gettext)

    {:noreply,
     socket
     |> assign(:acme_dns_test, :running)
     |> start_async(:acme_dns_test, fn ->
       Gettext.put_locale(AskDriveWeb.Gettext, locale)
       AskDrive.ACME.ValueDomain.test(config)
     end)}
  end

  def handle_event("run_acme", _params, %{assigns: %{scope: :platform}} = socket) do
    case AskDrive.ACME.Renewal.run("管理画面から手動") do
      :ok ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext(
             "Started getting the certificate. Waiting for DNS to propagate can take a few minutes. HTTPS restarts when it is applied, and the page reconnects by itself."
           )
         )}

      {:error, :running} ->
        {:noreply,
         put_flash(socket, :error, gettext("Getting the certificate is already in progress."))}

      {:error, :not_configured} ->
        {:noreply,
         put_flash(socket, :error, gettext("Save the host name, domain and API key first."))}
    end
  end

  # Update notices to Google Chat (F-1507)
  def handle_event(
        "save_notify_settings",
        %{"setting" => params},
        %{assigns: %{scope: :platform}} = socket
      ) do
    # blank keeps the stored URL (it is a secret and never shown)
    case Settings.update_setting(
           socket.assigns.setting,
           Map.take(params, ["google_chat_webhook_url"])
         ) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign_settings_form(updated)
         |> assign(:notify_test, nil)
         |> put_flash(
           :info,
           gettext("Google Chat notification destination saved. Check it with \"Send test\".")
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(
           :error,
           gettext("Could not save: %{errors}", errors: changeset_messages(changeset))
         )}
    end
  end

  def handle_event("test_google_chat", _params, %{assigns: %{scope: :platform}} = socket) do
    text =
      "✅ AskDrive からのテスト通知です（サーバー: #{AskDrive.Notify.GoogleChat.host()}・v#{AskDrive.version()}）"

    result =
      case AskDrive.Notify.GoogleChat.send_message(text, socket.assigns.setting) do
        :not_configured -> {:error, gettext("No webhook URL is set.")}
        other -> other
      end

    {:noreply, assign(socket, :notify_test, result)}
  end

  def handle_event("clear_google_chat", _params, %{assigns: %{scope: :platform}} = socket) do
    {:ok, updated} =
      socket.assigns.setting
      |> Ecto.Changeset.change(google_chat_webhook_url: nil)
      |> Repo.update()

    {:noreply,
     socket
     |> assign(:setting, updated)
     |> assign_settings_form(updated)
     |> assign(:notify_test, nil)
     |> put_flash(:info, gettext("Google Chat notification destination removed."))}
  end

  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: "#{socket.assigns.base_path}/admin?tab=#{tab}")}
  end

  @impl true
  def handle_event("retry_given_up", _params, socket) do
    count = Scheduler.retry_given_up_chunks()

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext(
         "%{count} chunks are back in line for QA generation. The next batch generates them again.",
         count: count
       )
     )
     |> load_dashboard_data()}
  end

  def handle_event("stop_batch", _params, socket) do
    socket =
      case Scheduler.request_stop() do
        :ok ->
          Logger.info("AdminLive: stop requested for the running batch")

          put_flash(
            socket,
            :info,
            gettext("Stop requested. The batch stops once the current item finishes.")
          )

        {:error, :not_running} ->
          put_flash(socket, :error, gettext("No batch is running."))
      end

    {:noreply, load_dashboard_data(socket)}
  end

  def handle_event("trigger_batch", params, socket) do
    ingest_only? = params["kind"] == "ingest_only"

    if Scheduler.running?() do
      {:noreply,
       put_flash(socket, :error, gettext("A batch is running. Run it again after it finishes."))}
    else
      Logger.info("AdminLive: Triggering manual batch run (ingest_only: #{ingest_only?})...")
      # bind: run the batch against this app's database (spec 6.11)
      Task.start(AskDrive.Apps.bind(fn -> Scheduler.run_batch(ingest_only: ingest_only?) end))

      message =
        if ingest_only?,
          do: gettext("Started an ingestion-only batch (no QA generation)."),
          else: gettext("Started a batch (with QA generation).")

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> load_dashboard_data()}
    end
  end

  @impl true
  # --- Ollama on the platform screen (F-837) ---

  def handle_event("install_ollama", _params, %{assigns: %{scope: :platform}} = socket) do
    by = (socket.assigns[:current_user] && socket.assigns.current_user.email) || "admin"

    case AskDrive.LLM.OllamaInstaller.install(by) do
      :ok ->
        {:noreply, assign(socket, :ollama_install, AskDrive.LLM.OllamaInstaller.status())}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, gettext("Ollama is already being installed."))}

      {:error, :unavailable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Ollama can't be installed from here: AskDrive wasn't started with app.sh.")
         )}
    end
  end

  def handle_event("start_ollama", _params, %{assigns: %{scope: :platform}} = socket) do
    {:noreply,
     socket
     |> assign(:ollama_starting, true)
     |> start_async(:start_ollama, fn ->
       AskDrive.LLM.OllamaServer.ensure_running(Settings.platform_setting!())
     end)}
  end

  def handle_event("refresh_ollama", _params, socket),
    do: {:noreply, assign_ollama_runtime(socket)}

  # on a desk's screen there's nothing to pull or delete (F-838)
  def handle_event(event, _params, socket)
      when event in ["pull_model", "pull_missing_models", "delete_model"],
      do: {:noreply, socket}

  # Which provider fields the AI settings show follows the form as it is edited, before it is
  # saved: only the selected side's (local or cloud) fields are shown.
  def handle_event("settings_change", %{"setting" => params}, socket) do
    before = socket.assigns.llm_view
    socket = assign(socket, :llm_view, llm_view_from_params(params, before))

    # switched to Ollama before saving: its pulled models, for the pull-downs (F-838)
    socket =
      if "ollama" in socket.assigns.llm_view.in_use and "ollama" not in before.in_use,
        do: assign_ollama_models(socket),
        else: socket

    {:noreply, maybe_load_cloud_models(socket)}
  end

  def handle_event("save_settings", %{"setting" => setting_params}, socket) do
    setting_params =
      setting_params
      |> normalize_chat_summary_params()
      |> put_ollama_embedding_dim(socket.assigns.ollama_catalog, socket.assigns.setting)

    case unpulled_ollama_models(
           setting_params,
           socket.assigns.ollama_catalog,
           socket.assigns.setting
         ) do
      [] ->
        save_settings(socket, setting_params)

      models ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Not saved: %{models} isn't one of Ollama's pulled models. Choose a pulled model (a platform administrator pulls them in the platform settings).",
             models: join_list(models)
           )
         )}
    end
  end

  def handle_event("settings_change", _params, socket), do: {:noreply, socket}

  def handle_event("refresh_cloud_models", _params, socket) do
    {:noreply, maybe_load_cloud_models(socket, force: true)}
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
         |> assign_settings_form(updated)
         |> assign(:service_account_test, nil)
         |> assign_drive_mode()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not switch the Drive authentication method."))}
    end
  end

  # Typing in the Drive card: the account to authorize (its hint goes into a fresh
  # authorization URL) and the pasted address (F-347), kept until 保存して認証完了 (F-353)
  @impl true
  def handle_event("drive_form_change", params, socket) do
    hint = String.trim(params["drive_login_hint"] || socket.assigns[:drive_login_hint] || "")

    socket =
      if hint != socket.assigns[:drive_login_hint] and socket.assigns[:drive_oauth_ready?],
        do:
          socket
          |> assign(:drive_login_hint, hint)
          |> assign(:drive_auth, new_drive_auth(socket, hint)),
        else: socket

    pasted = params["drive_auth_code"] || socket.assigns[:drive_auth_code] || ""

    {:noreply, assign(socket, :drive_auth_code, pasted)}
  end

  # 接続テスト for an OAuth client (F-349): the platform's, or the one this desk uses
  def handle_event("test_oauth_client", %{"scope" => scope}, socket) do
    alias AskDrive.Drive.OAuth

    {key, client} =
      if scope == "desk",
        do: {:desk, OAuth.drive_client()},
        else: {:platform, {OAuth.get_client_id(), OAuth.get_client_secret()}}

    result =
      case OAuth.test_client(client) do
        :ok -> {:ok, gettext("The client ID / secret is valid (Google recognizes it).")}
        {:error, message} -> {:error, message}
      end

    {:noreply,
     Phoenix.Component.update(socket, :oauth_client_test, &Map.put(&1 || %{}, key, result))}
  end

  # 接続 without an OAuth client: open its section and say what's needed
  def handle_event("drive_connect_needs_client", _params, socket) do
    {:noreply,
     socket
     |> assign(:drive_client_open, true)
     |> put_flash(
       :error,
       gettext(
         "Connecting needs an OAuth client. Register one in the platform settings under \"Google OAuth (login / Drive sync)\", or enter one below under \"OAuth client (first time only)\" and save."
       )
     )}
  end

  def handle_event("drive_auth_finish", _params, socket), do: finish_drive_auth(socket)

  # The Drive card's single save (F-345): the chosen mode's authentication and the folder
  @impl true
  def handle_event("save_drive_settings", %{"setting" => params} = form_params, socket) do
    folder = Map.take(params, ["drive_folder_id", "drive_folder_name"])

    if socket.assigns.drive_mode == "service_account" do
      save_service_account_params(socket, params, folder)
    else
      attrs =
        params
        |> Map.take(["drive_oauth_client_id", "drive_oauth_client_secret"])
        |> Map.merge(folder)

      pasted = String.trim(form_params["drive_auth_code"] || "")

      # Enter in the paste box submits the card: the pasted address is completed as well,
      # as with 保存して認証完了 (F-353)
      case save_drive_settings(socket, attrs) do
        {:noreply, socket} when pasted != "" ->
          socket |> assign(:drive_auth_code, pasted) |> finish_drive_auth()

        reply ->
          reply
      end
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
          {:error, gettext("Save the JSON key first.")}
      end

    {:noreply, assign(socket, :service_account_test, result)}
  end

  # A dry run of the sync (F-345): authenticate, read the folder and list what would be
  # synced, without ingesting anything. Listing a large folder takes a while, so it's async.
  @impl true
  def handle_event("test_drive_sync", _params, socket) do
    setting = socket.assigns.setting

    cond do
      not Accounts.drive_connected?() ->
        {:noreply,
         assign(
           socket,
           :drive_sync_test,
           {:error,
            gettext(
              "Set up authentication first (a service account JSON key, or OAuth authorization)."
            )}
         )}

      setting.drive_folder_id in [nil, ""] ->
        {:noreply,
         assign(
           socket,
           :drive_sync_test,
           {:error, gettext("Enter and save the ID / URL of the folder to sync.")}
         )}

      true ->
        folder_id = setting.drive_folder_id
        locale = Gettext.get_locale(AskDriveWeb.Gettext)

        {:noreply,
         socket
         |> assign(:drive_sync_test, :running)
         |> start_async(
           :drive_sync_test,
           AskDrive.Apps.bind(fn ->
             Gettext.put_locale(AskDriveWeb.Gettext, locale)
             drive_sync_dry_run(folder_id, setting)
           end)
         )}
    end
  end

  @impl true
  def handle_event("disconnect_service_account", _params, socket) do
    Accounts.disconnect_service_account()

    {:noreply,
     socket
     |> assign(:setting, Settings.get_setting!())
     |> assign(:service_account_test, nil)
     |> put_flash(:info, gettext("Service account credentials removed."))
     |> load_dashboard_data()}
  end

  @impl true
  def handle_event("set_admin_eligible", %{"id" => id, "eligible" => eligible}, socket) do
    actor = socket.assigns.current_user
    target = Accounts.get_user(id)

    case Accounts.set_admin_eligible(actor, target, eligible == "true") do
      # handing over (F-921): the elevation ends at the next request; leave the admin screen
      {:ok, %{id: id}} when id == actor.id ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Your platform administrator role was removed. You are now a regular user.")
         )
         |> redirect(to: ~p"/")}

      result ->
        handle_user_change(result, socket)
    end
  end

  @impl true
  # A platform administrator changing an app's administrators from the users tab (recovery,
  # F-1114): recorded and shown on the app's screen; the last one can't be removed
  def handle_event("toggle_user_app_admin", %{"user_id" => user_id, "app_slug" => slug}, socket) do
    user = Accounts.get_user(user_id)
    app = AskDrive.Apps.get_by_slug(slug)

    if user && app do
      actor = socket.assigns.current_user

      result =
        if Accounts.assigned_app_admin?(user, slug),
          do: AppAdminAccess.remove_admin(actor, app, user),
          else: AppAdminAccess.add_admins(actor, app, [user.email])

      case result do
        :ok ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Updated the desk administrator roles of %{email}.", email: user.email)
           )
           |> load_dashboard_data()}

        {:error, :last_admin} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext(
               "Desk \"%{name}\" can't have zero administrators. Add another administrator first.",
               name: app.name
             )
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("User not found."))}
    end
  end

  # suggestions for the address being typed (F-1115)
  @impl true
  def handle_event("ac_suggest", %{"field" => field, "value" => value}, socket) do
    {_head, last} = split_last_address(value)
    suggestions = AskDrive.Ldap.search_users(Settings.platform_setting!(), last)

    {:noreply,
     Phoenix.Component.update(
       socket,
       :ac,
       &Map.put(&1, field, %{value: value, suggestions: suggestions})
     )}
  end

  def handle_event("ac_pick", %{"field" => field, "email" => email}, socket) do
    value = get_in(socket.assigns.ac, [field, :value]) || ""
    {head, _last} = split_last_address(value)

    {:noreply,
     Phoenix.Component.update(
       socket,
       :ac,
       &Map.put(&1, field, %{value: head <> email <> ", ", suggestions: []})
     )}
  end

  # The app's administrators (F-1114): added by e-mail (before their first sign-in too) by
  # an administrator of the app, or by a platform administrator recovering it
  @impl true
  def handle_event("add_app_admins", %{"app_slug" => slug, "emails" => text}, socket) do
    app = AskDrive.Apps.get_by_slug!(slug)

    with {:ok, emails} <- parse_admin_emails(text, Settings.platform_setting!().allowed_domain),
         :ok <- check_directory(emails),
         :ok <- AppAdminAccess.add_admins(socket.assigns.current_user, app, emails) do
      {:noreply,
       socket
       |> clear_ac("add-app-admins-emails")
       |> put_flash(
         :info,
         gettext("%{emails} are now administrators of desk \"%{name}\".",
           emails: join_list(emails),
           name: app.name
         )
       )
       |> load_dashboard_data()}
    else
      {:error, :not_authorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not allowed to change the administrators."))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("remove_app_admin", %{"app_slug" => slug, "user_id" => id}, socket) do
    app = AskDrive.Apps.get_by_slug!(slug)
    actor = socket.assigns.current_user
    user = Accounts.get_user(String.to_integer(id))

    case AppAdminAccess.remove_admin(actor, app, user) do
      # gave up their own role: the screen closes at once
      :ok when user.id == actor.id and socket.assigns.scope == :app ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("You are no longer an administrator of desk \"%{name}\".", name: app.name)
         )
         |> redirect(to: "/" <> app.slug)}

      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Removed %{email} from the administrators of desk \"%{name}\".",
             email: user.email,
             name: app.name
           )
         )
         |> load_dashboard_data()}

      {:error, :last_admin} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("A desk can't have zero administrators. Add another administrator first.")
         )}

      {:error, :not_authorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not allowed to change the administrators."))}
    end
  end

  @impl true
  # Saves the password only; the restriction is switched on and off separately (F-206)
  def handle_event("save_access_password", %{"access_password" => params}, socket) do
    new_password = params["password"] || ""
    confirmation = params["confirmation"] || ""

    result =
      if new_password != confirmation,
        do: {:error, :mismatch},
        else: AdminAccess.set_access_password(socket.assigns.setting, new_password)

    case result do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> put_flash(
           :info,
           if(updated.access_password_enabled,
             do: gettext("Desk access password changed."),
             else:
               gettext(
                 "Desk access password saved. Turn the restriction on with the \"Restrict access by password\" switch."
               )
           )
         )
         |> load_dashboard_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, password_error_message(reason))}
    end
  end

  # --- On/off switches (F-206): apply at once, separately from saving the values ---

  @setting_toggles %{
    "auto_batch" => {:auto_batch_enabled, gettext_noop("Nightly batch")},
    "maintenance_mode" => {:maintenance_mode, gettext_noop("Maintenance mode")},
    "serve_stale_qa" => {:serve_stale_qa, gettext_noop("Serving stale QA pairs")},
    "daytime_llm" => {:daytime_llm_enabled, gettext_noop("LLM generation during business hours")},
    "chat_summary" => {:chat_summary_enabled, gettext_noop("AI summary in chat")},
    "update_check" => {:update_check_enabled, gettext_noop("Nightly check for new versions")},
    "update_auto_apply" => {:update_auto_apply, gettext_noop("Automatic updates")}
  }
  @platform_toggles ~w(update_check update_auto_apply oauth_login ldap gateway acme)

  def handle_event("toggle_feature", %{"feature" => feature, "on" => on}, socket) do
    on? = on == "true"

    result =
      if feature in @platform_toggles and socket.assigns.scope != :platform,
        do: {:error, gettext("It can't be switched on this screen"), gettext("This feature")},
        else: set_feature(feature, on?, socket)

    case result do
      {:ok, socket, label} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           if(on?,
             do: gettext("%{feature} turned on.", feature: label),
             else: gettext("%{feature} turned off.", feature: label)
           )
         )}

      {:error, message, label} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           if(on?,
             do:
               gettext("%{feature} could not be turned on: %{message}",
                 feature: label,
                 message: message
               ),
             else:
               gettext("%{feature} could not be turned off: %{message}",
                 feature: label,
                 message: message
               )
           )
         )}
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

  defp password_error_message(:mismatch), do: gettext("The new passwords don't match.")

  defp password_error_message(:too_short),
    do:
      gettext("The password must be at least %{count} characters.",
        count: AdminAccess.min_password_length()
      )

  defp password_error_message(:surrounding_whitespace),
    do: gettext("The password must not start or end with spaces.")

  defp password_error_message(:not_authorized), do: gettext("You are not allowed to do this.")
  defp password_error_message(_), do: gettext("Could not set or change the password.")

  defp handle_user_change({:ok, user}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Updated %{email}.", email: user.email))
     |> load_dashboard_data()}
  end

  defp handle_user_change({:error, :fixed_by_env}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "This address is fixed as a platform administrator by ASK_DRIVE_ADMIN_EMAILS in .env.prod (it is restored at the next sign-in). Remove it from .env.prod on the server, run ./app.sh restart, then try again."
       )
     )}
  end

  defp handle_user_change({:error, :cannot_modify_self}, socket) do
    {:noreply, put_flash(socket, :error, gettext("You can't change your own role or status."))}
  end

  defp handle_user_change({:error, :last_admin}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "At least one account must be eligible for admin elevation. Allow another account to elevate first."
       )
     )}
  end

  defp handle_user_change({:error, _changeset}, socket) do
    {:noreply, put_flash(socket, :error, gettext("Could not update the user."))}
  end

  # `<.input type="select">` wants {label, value} pairs; the identifiers themselves are too
  # terse to show to an operator.
  # Secrets are never echoed back into the form; the admin only needs to know whether one
  # is stored (N-610).
  defp secret_state(value) when is_binary(value) and value != "", do: gettext("Set")
  defp secret_state(_), do: gettext("Not set")

  # --- The cloud API's model pull-down (F-834) ------------------------------------------

  # The models of the cloud provider chosen for the nightly batch, asked in the background
  # (the provider's API can take seconds) with the saved API key, once per provider unless
  # forced. The task gets this viewer's locale for its messages.
  defp maybe_load_cloud_models(socket, opts \\ []) do
    view = socket.assigns.llm_view
    provider = view.cloud
    force? = Keyword.get(opts, :force, false)
    current = Map.get(socket.assigns.cloud_models, provider)

    if socket.assigns.scope == :app and connected?(socket) and view.batch == "cloud" and
         current != :loading and (force? or is_nil(current)) do
      setting = socket.assigns.setting
      locale = Gettext.get_locale(AskDriveWeb.Gettext)

      socket
      |> assign(:cloud_models, Map.put(socket.assigns.cloud_models, provider, :loading))
      |> start_async({:cloud_models, provider}, fn ->
        Gettext.put_locale(AskDriveWeb.Gettext, locale)
        AskDrive.LLM.CloudModels.list(provider, setting, force: force?)
      end)
    else
      socket
    end
  end

  # A desk's Ollama model field (F-838): a choice among the models pulled on the platform
  # screen that can do `kind` — only those; a desk can't pull one itself. A saved name that
  # isn't one of them (not pulled, or not an Ollama model at all, e.g. left over from a cloud
  # API) is pointed out and must be replaced: the field then starts empty and, where a model
  # is needed (`required`), the form isn't sent until one is chosen. Without a connection to
  # Ollama the name is typed.
  attr :field, Phoenix.HTML.FormField, required: true
  attr :kind, :atom, required: true, values: [:embedding, :generation]
  attr :catalog, :any, required: true
  attr :label, :string, required: true
  attr :prompt, :string, default: nil, doc: "the blank choice's label (blank allowed)"
  attr :required, :boolean, default: false
  attr :default, :string, default: nil, doc: "the model in effect when the saved one is blank"

  defp ollama_model_field(assigns) do
    # judged by the model actually in effect: a blank field falls back (e.g. to
    # ASK_DRIVE_EMBED_MODEL from .env.prod), which the pull-down mustn't hide
    current =
      case to_string(assigns.field.value || "") do
        "" -> to_string(assigns.default || "")
        value -> value
      end

    stale? =
      match?({:ok, _}, assigns.catalog) and current != "" and
        not AskDrive.LLM.OllamaModels.choosable?(elem(assigns.catalog, 1), assigns.kind, current)

    assigns = assign(assigns, current: current, stale?: stale?)

    ~H"""
    <div>
      <%= case @catalog do %>
        <% {:ok, models} -> %>
          <.input
            field={@field}
            type="select"
            label={@label}
            value={if(@stale?, do: "", else: @current)}
            prompt={@prompt || gettext("Choose a pulled model")}
            options={AskDrive.LLM.OllamaModels.options(models, @kind)}
            required={@required and @prompt == nil}
          />
          <p
            :if={@stale?}
            class="mt-1 text-[11px] text-amber-700 dark:text-amber-300 leading-snug"
          >
            {gettext(
              "The saved model %{model} isn't one of the pulled models (it may not be an Ollama model at all). Choose one of the pulled models and save.",
              model: @current
            )}
          </p>
          <p
            :if={AskDrive.LLM.OllamaModels.options(models, @kind) == []}
            class="mt-1 text-[11px] text-amber-700 dark:text-amber-300 leading-snug"
          >
            {gettext(
              "No suitable model is pulled yet: ask a platform administrator to pull one (platform settings, Ollama)."
            )}
          </p>
        <% {:error, _} -> %>
          <.input field={@field} type="text" label={@label} placeholder={@prompt} />
          <p class="mt-1 text-[11px] text-zinc-500 leading-snug">
            {gettext("Ollama can't be reached, so the pulled models can't be listed.")}
          </p>
      <% end %>
    </div>
    """
  end

  # The endpoint and key fields of one provider (F-836), shown right under the setting that
  # uses it — the nightly batch's, the chat summary's or the embedding's provider — and only
  # once when several use the same one. API keys are stored encrypted; a blank key keeps the
  # saved one.
  attr :provider, :string, required: true
  attr :form, :any, required: true
  attr :setting, :any, required: true

  defp provider_connection(assigns) do
    ~H"""
    <div class="p-3 rounded-lg bg-white/70 dark:bg-zinc-900/60 border border-zinc-200/70 dark:border-zinc-800 space-y-2">
      <p class="text-[11px] font-semibold text-zinc-600 dark:text-zinc-300 flex items-center gap-1">
        <.icon name="hero-key" class="w-3.5 h-3.5 text-indigo-500" />
        {gettext("Connection: %{provider}", provider: LLM.label(@provider))}
      </p>
      <%= case @provider do %>
        <% "ollama" -> %>
          <div
            id="connection-ollama"
            class="grid grid-cols-1 sm:grid-cols-2 gap-4"
          >
            <.input
              field={@form[:ollama_host]}
              type="text"
              label={gettext("Ollama endpoint")}
              placeholder={LLM.default_base_url("ollama")}
            />
            <.input
              field={@form[:batch_num_ctx]}
              type="number"
              label={gettext("Ollama context length (num_ctx)")}
            />
          </div>
        <% "lmstudio" -> %>
          <div
            id="connection-lmstudio"
            class="grid grid-cols-1 sm:grid-cols-2 gap-4"
          >
            <.input
              field={@form[:lmstudio_base_url]}
              type="text"
              label={gettext("LM Studio endpoint")}
              placeholder={LLM.default_base_url("lmstudio")}
            />
          </div>
        <% "gemini" -> %>
          <div
            id="connection-gemini"
            class="grid grid-cols-1 sm:grid-cols-2 gap-4"
          >
            <.input
              field={@form[:gemini_api_key]}
              type="password"
              value=""
              label={
                gettext("Google Gemini API key (%{key})",
                  key: LLM.masked_api_key("gemini", @setting)
                )
              }
              placeholder={key_placeholder("gemini", @setting, "AIza...")}
            />
            <.input
              field={@form[:gemini_base_url]}
              type="text"
              label={gettext("Gemini base URL")}
              placeholder={LLM.default_base_url("gemini")}
            />
          </div>
        <% "vertex" -> %>
          <%!-- Agent Platform (formerly Vertex AI) with an API key (F-835): no project
              means the global endpoint the API key is documented with --%>
          <div
            id="connection-vertex"
            class="grid grid-cols-1 sm:grid-cols-3 gap-4"
          >
            <.input
              field={@form[:vertex_api_key]}
              type="password"
              value=""
              label={
                gettext("Agent Platform (Vertex AI) API key (%{key})",
                  key: LLM.masked_api_key("vertex", @setting)
                )
              }
              placeholder={key_placeholder("vertex", @setting, "")}
            />
            <.input
              field={@form[:vertex_project]}
              type="text"
              label={gettext("Google Cloud project ID (optional)")}
              placeholder={gettext("Blank: the global endpoint")}
            />
            <.input
              field={@form[:vertex_location]}
              type="text"
              label={gettext("Location (optional)")}
              placeholder="global"
            />
            <p class="sm:col-span-3 -mt-2 text-[11px] text-zinc-500 leading-relaxed">
              {gettext(
                "Create the key in the Google Cloud console (Agent Platform › API keys, or express mode). With the project ID blank, requests go to the global endpoint (aiplatform.googleapis.com); enter a project ID and location to use that project's endpoint, e.g. asia-northeast1 (Tokyo) to keep processing in Japan."
              )}
              <span class="block font-mono text-zinc-400 mt-0.5">
                {LLM.base_url("vertex", @setting)}
              </span>
            </p>
          </div>
        <% "anthropic" -> %>
          <div
            id="connection-anthropic"
            class="grid grid-cols-1 sm:grid-cols-2 gap-4"
          >
            <.input
              field={@form[:anthropic_api_key]}
              type="password"
              value=""
              label={
                gettext("Anthropic Claude API key (%{key})",
                  key: LLM.masked_api_key("anthropic", @setting)
                )
              }
              placeholder={key_placeholder("anthropic", @setting, "sk-ant-...")}
            />
            <.input
              field={@form[:anthropic_base_url]}
              type="text"
              label={gettext("Anthropic base URL")}
              placeholder={LLM.default_base_url("anthropic")}
            />
          </div>
        <% "openai" -> %>
          <div
            id="connection-openai"
            class="grid grid-cols-1 sm:grid-cols-2 gap-4"
          >
            <.input
              field={@form[:openai_api_key]}
              type="password"
              value=""
              label={
                gettext("OpenAI API key (%{key})",
                  key: LLM.masked_api_key("openai", @setting)
                )
              }
              placeholder={key_placeholder("openai", @setting, "sk-...")}
            />
            <.input
              field={@form[:openai_base_url]}
              type="text"
              label={gettext("OpenAI base URL")}
              placeholder={LLM.default_base_url("openai")}
            />
          </div>
        <% _ -> %>
      <% end %>
    </div>
    """
  end

  defp save_settings(socket, setting_params) do
    # `vec0` fixes the vector width at CREATE time, so a new embedding model or dimension
    # means dropping and rebuilding the index before anything can be re-embedded (F-809).
    reindex? = Settings.reindex_required?(socket.assigns.setting, setting_params)

    case Settings.update_setting(socket.assigns.setting, setting_params) do
      {:ok, updated} ->
        # whether Ollama is needed now (and running if so); pulling models is the platform
        # administrator's (F-838)
        AskDrive.LLM.OllamaModels.sync_needed(updated)

        message =
          if reindex? do
            case Vector.rebuild_index(updated.embedding_dim) do
              {:ok, _dim} ->
                gettext(
                  "Settings saved and the vector index rebuilt. The next nightly batch re-embeds all chunks."
                )

              {:error, reason} ->
                Logger.error("Vector index rebuild failed: #{inspect(reason)}")
                gettext("Settings saved, but rebuilding the vector index failed. Check the logs.")
            end
          else
            gettext("Settings saved.")
          end

        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign_settings_form(updated)
         |> assign(:cloud_models, %{})
         |> maybe_load_cloud_models()
         |> put_flash(:info, message)
         |> load_dashboard_data()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign(:llm_view, llm_view_from_params(setting_params, socket.assigns.llm_view))
         |> put_flash(:error, gettext("Could not save the settings. Check your input."))}
    end
  end

  # --- A desk's Ollama models: only pulled ones (F-838) ---------------------------------

  # The Ollama model fields being saved, with the provider each one runs on
  defp ollama_model_fields(params, setting) do
    get = fn key ->
      Map.get(params, key, to_string(Map.get(setting, String.to_existing_atom(key)) || ""))
    end

    batch_provider = if get.("batch_llm_mode") == "cloud", do: nil, else: get.("llm_provider")

    chat_provider =
      case get.("chat_summary_provider") do
        "" ->
          if get.("batch_llm_mode") == "cloud",
            do: get.("cloud_llm_provider"),
            else: batch_provider

        provider ->
          provider
      end

    [
      {"batch_model", :generation, batch_provider},
      {"chat_summary_model", :generation, chat_provider},
      {"embed_model", :embedding, get.("embed_provider")}
    ]
    |> Enum.filter(fn {key, _kind, provider} ->
      provider == "ollama" and Map.has_key?(params, key)
    end)
  end

  # Names sent for Ollama fields that aren't pulled models of the right kind (only checked
  # when Ollama could be asked; blank means "the default" and is left to the settings)
  defp unpulled_ollama_models(params, {:ok, models}, setting) do
    for {key, kind, _provider} <- ollama_model_fields(params, setting),
        name = String.trim(params[key] || ""),
        name != "",
        not AskDrive.LLM.OllamaModels.choosable?(models, kind, name),
        do: name
  end

  defp unpulled_ollama_models(_params, _catalog, _setting), do: []

  # An Ollama embedding model's vectors have the size the model says: the dimension follows it
  # (a leftover 768 from a cloud model would make every embedding fail)
  defp put_ollama_embedding_dim(params, {:ok, models}, setting) do
    with true <- Enum.any?(ollama_model_fields(params, setting), &(elem(&1, 0) == "embed_model")),
         %{embedding_length: length} when is_integer(length) <-
           AskDrive.LLM.OllamaModels.find(models, params["embed_model"]) do
      Map.put(params, "embedding_dim", Integer.to_string(length))
    else
      _ -> params
    end
  end

  defp put_ollama_embedding_dim(params, _catalog, _setting), do: params

  # A saved API key isn't shown (it would sit in every page sent, in screen shares and the
  # browser's history); the field says it's set, with its last 4 characters, and stays empty:
  # typing replaces it, leaving it blank keeps it. The connection test tells a wrong key.
  defp key_placeholder(provider, setting, example) do
    case LLM.api_key(provider, setting) do
      key when is_binary(key) and byte_size(key) >= 4 ->
        gettext("Set: ••••••••%{last4} (type only to replace it)",
          last4: String.slice(key, -4, 4)
        )

      key when is_binary(key) and key != "" ->
        gettext("Set (type only to replace it)")

      _ ->
        example
    end
  end

  defp provider_options(providers) do
    Enum.map(providers, fn provider -> {LLM.label(provider), provider} end)
  end

  defp assign_settings_form(socket, setting) do
    socket
    |> assign(:form, to_form(Settings.change_setting(setting)))
    |> assign(:llm_view, llm_view(setting))
  end

  # --- Local or cloud: which AI fields the settings form shows ---------------------------

  @local_llm_providers Enum.filter(
                         AskDrive.Settings.Setting.generation_providers(),
                         &LLM.local?/1
                       )
  @cloud_llm_providers AskDrive.Settings.Setting.cloud_providers()

  defp llm_providers_for("local"), do: @local_llm_providers
  defp llm_providers_for(_cloud), do: @cloud_llm_providers

  # The nightly batch's and the chat summary's choice of local or cloud, the providers chosen
  # on each side, and the embedding provider.
  defp llm_view(setting) do
    chat_provider = setting.chat_summary_provider

    chat =
      cond do
        chat_provider in [nil, ""] -> "same"
        LLM.local?(chat_provider) -> "local"
        true -> "cloud"
      end

    build_llm_view(%{
      batch: if(setting.batch_llm_mode == "cloud", do: "cloud", else: "local"),
      local: setting.llm_provider,
      cloud: setting.cloud_llm_provider,
      chat: chat,
      chat_provider: chat_provider,
      embed: LLM.embedding_provider(setting)
    })
  end

  defp llm_view_from_params(params, current) do
    build_llm_view(%{
      batch: if(params["batch_llm_mode"] == "cloud", do: "cloud", else: "local"),
      local: params["llm_provider"] || current.local,
      cloud: params["cloud_llm_provider"] || current.cloud,
      chat:
        if(params["chat_summary_mode"] in ~w(same local cloud),
          do: params["chat_summary_mode"],
          else: current.chat
        ),
      chat_provider: params["chat_summary_provider"] || current.chat_provider,
      embed: params["embed_provider"] || current.embed
    })
  end

  # A provider that isn't on the chosen side (the select is about to list the other side's)
  # becomes that side's first, as the browser will show it.
  defp build_llm_view(view) do
    local = pick(view.local, @local_llm_providers)
    cloud = pick(view.cloud, @cloud_llm_providers)
    batch_provider = if view.batch == "cloud", do: cloud, else: local

    chat_provider =
      if view.chat == "same",
        do: batch_provider,
        else: pick(view.chat_provider, llm_providers_for(view.chat))

    chat_side =
      if view.chat == "same", do: view.batch, else: view.chat

    # where each provider's connection fields go (F-836): under the first of the nightly
    # batch, the chat summary (its own provider) and the embedding that uses it
    connection_at =
      [
        {:batch, batch_provider},
        {:chat, view.chat != "same" && chat_provider},
        {:embed, view.embed}
      ]
      |> Enum.reduce(%{}, fn
        {_slot, provider}, acc when provider in [nil, false] -> acc
        {slot, provider}, acc -> Map.put_new(acc, provider, slot)
      end)

    view
    |> Map.merge(%{local: local, cloud: cloud, chat_provider: chat_provider})
    |> Map.merge(%{
      batch_provider: batch_provider,
      chat_side: chat_side,
      in_use: Enum.uniq([batch_provider, chat_provider, view.embed]),
      connection_at: connection_at
    })
  end

  defp pick(provider, providers), do: if(provider in providers, do: provider, else: hd(providers))

  # 「夜間バッチと同じ」 is stored as no chat summary provider of its own.
  defp normalize_chat_summary_params(%{"chat_summary_mode" => "same"} = params),
    do: params |> Map.delete("chat_summary_mode") |> Map.put("chat_summary_provider", "")

  defp normalize_chat_summary_params(params), do: Map.delete(params, "chat_summary_mode")

  defp load_dashboard_data(socket) do
    # 1. Batch history (spec F-338): recent runs, the one being inspected (latest unless the
    #    admin picked another row), and what the night-window trigger is doing.
    runs = Scheduler.list_runs(20)
    selected_id = socket.assigns[:selected_run_id]
    latest_run = Enum.find(runs, &(&1.id == selected_id)) || List.first(runs)
    item_logs = if latest_run, do: ItemLog.list_for_run(latest_run.id), else: []
    run_summaries = runs |> Enum.map(& &1.id) |> ItemLog.summaries()
    auto_status = Scheduler.auto_status()

    # a desk still switched off whose Drive and AI are configured: suggest switching it on
    setup_looks_done? =
      auto_status.state == :off and Accounts.drive_connected?() and
        is_nil(AskDrive.LLM.missing_api_key(:embedding)) and
        is_nil(AskDrive.LLM.missing_api_key(:generation))

    # progress of the run in progress (spec F-340); the dashboard ticks every 5 s
    # (or one waiting for its turn to generate in the nightly batch, F-355)
    running_run = Enum.find(runs, &(&1.status in ["running", "waiting"]))

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

    # 6. Metrics & API Usage
    metrics_summary = AskDrive.Metrics.get_summary(30)
    recent_api_errors = AskDrive.Metrics.list_recent_errors(20)
    data_efficiency = AskDrive.Metrics.get_data_efficiency_summary()

    socket
    |> assign(
      :app_summaries,
      if(socket.assigns[:scope] == :platform, do: app_summaries(), else: %{})
    )
    |> assign_ollama_models()
    |> assign(:users, users)
    |> assign(:elevation_logs, AdminAccess.list_elevation_logs(100))
    |> assign(:generation_provider, LLM.generation_provider(setting))
    |> assign(:embedding_provider, LLM.embedding_provider(setting))
    |> assign(:latest_run, latest_run)
    |> assign(:runs, runs)
    |> assign(:run_summaries, run_summaries)
    |> assign(:auto_status, auto_status)
    |> assign(:setup_looks_done?, setup_looks_done?)
    |> assign_drive_mode()
    |> assign(:running_run, running_run)
    |> assign(:remaining, Scheduler.remaining())
    |> assign(:client_cert_mode, AskDrive.ClientCerts.mode())
    |> assign(:client_cert_lan, AskDrive.ClientCerts.lan_ranges())
    |> assign(
      :client_cert_groups,
      if(socket.assigns[:scope] == :platform, do: AskDrive.ClientCerts.list_groups(), else: [])
    )
    |> assign(
      :users_without_cert,
      if(socket.assigns[:scope] == :platform,
        do: AskDrive.ClientCerts.users_without_cert(),
        else: []
      )
    )
    # each app's administrators (F-1114): the platform's app list, and the app's own card
    |> assign(
      :app_admins,
      case socket.assigns[:scope] do
        :platform -> Map.new(AskDrive.Apps.list(), &{&1.slug, AppAdminAccess.admins(&1)})
        _ -> %{socket.assigns.app.slug => AppAdminAccess.admins(socket.assigns.app)}
      end
    )
    |> assign(
      :app_admin_changes,
      if(socket.assigns[:scope] == :app,
        do: AppAdminAccess.admin_changes(socket.assigns.app),
        else: []
      )
    )
    |> assign(
      :login_locks,
      if(socket.assigns[:scope] == :platform,
        do: AskDrive.Accounts.LoginThrottle.active_locks(),
        else: []
      )
    )
    |> assign(:given_up_chunks, Scheduler.given_up_chunks(50))
    |> assign(:running_progress, running_run && progress_view(running_run))
    |> assign(:selected_progress, latest_run && progress_view(latest_run))
    |> assign(:item_logs, item_logs)
    |> assign(:total_chunks, total_chunks)
    |> assign(:active_qas, active_qas)
    |> assign(:stale_qas, stale_qas)
    |> assign(:total_docs, total_docs)
    |> assign(:documents, docs)
    |> assign(:unresolved_questions, unresolved_questions)
    |> assign(:resolved_questions, resolved_questions)
    |> assign(:metrics_summary, metrics_summary)
    |> assign(:recent_api_errors, recent_api_errors)
    |> assign(:data_efficiency, data_efficiency)
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
      app={@app}
      apps={@apps}
      current={if @scope == :app, do: :app_admin, else: :platform_admin}
      wide
    >
      <div class="space-y-6 pb-12">
        <%!-- Header Bar --%>
        <%!-- Which of the two admin screens this is: Platform Admin carries the indigo of the
              admin-mode group in the header, a desk's admin screen stays neutral. --%>
        <div class={[
          "flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-4 border-b",
          if(@scope == :platform,
            do: "border-indigo-200 dark:border-indigo-800 border-l-4 border-l-indigo-500 pl-4",
            else: "border-zinc-200 dark:border-zinc-800"
          )
        ]}>
          <div>
            <p
              id="admin-scope-label"
              class={[
                "inline-flex items-center gap-1 text-[11px] font-semibold mb-1",
                if(@scope == :platform,
                  do: "text-indigo-700 dark:text-indigo-300",
                  else: "text-zinc-500"
                )
              ]}
            >
              <%= if @scope == :platform do %>
                <.icon name="hero-shield-check" class="w-3.5 h-3.5" /> {gettext(
                  "Applies to all desks"
                )}
              <% else %>
                <.icon name="hero-chat-bubble-left-right" class="w-3.5 h-3.5" /> {gettext(
                  "Applies to this desk only"
                )}
              <% end %>
            </p>
            <div class="flex items-center gap-2">
              <h1 class="font-bold text-2xl text-zinc-900 dark:text-zinc-100">
                {if @scope == :app,
                  do: gettext("Manage %{name}", name: @app.name),
                  else: gettext("Platform admin")}
              </h1>
              <span
                id="app-version"
                title={gettext("Running AskDrive version")}
                class="text-[11px] font-mono px-2 py-0.5 rounded-full bg-zinc-100 dark:bg-zinc-800 text-zinc-500"
              >
                v{AskDrive.version()}
              </span>
              <% available = @scope == :platform && AskDrive.Updates.available_version(@setting) %>
              <.link
                :if={available}
                id="update-available-badge"
                patch="/admin?tab=update"
                class="text-[11px] font-medium px-2 py-0.5 rounded-full bg-indigo-600 hover:bg-indigo-700 text-white transition"
              >
                {gettext("v%{version} available", version: available)}
              </.link>
            </div>
            <p class="text-xs text-zinc-500 mt-1">
              {if @scope == :app,
                do:
                  gettext(
                    "Manage this desk's nightly batch, documents, unanswered questions, and Google Drive and AI settings."
                  ),
                else:
                  gettext(
                    "Manage settings for all of AskDrive: adding and managing desks (apps), users, HTTPS, local models, the nightly batch window, and more."
                  )}
            </p>
          </div>

          <%!-- While this app's batch runs, the trigger buttons give way to stopping it (F-341) --%>
          <div :if={@scope == :app && @running_run} class="flex flex-wrap items-center gap-2">
            <%= if @running_run.stop_requested_at do %>
              <span
                id="stop-requested"
                class="text-xs px-3.5 py-2 rounded-lg bg-amber-50 dark:bg-amber-950/40 border border-amber-200 dark:border-amber-900 text-amber-800 dark:text-amber-200 flex items-center gap-1.5"
              >
                <.icon name="hero-clock" class="w-4 h-4" /> {gettext(
                  "Stop requested. It will stop once the current item finishes."
                )}
              </span>
            <% else %>
              <button
                id="stop-batch-btn"
                phx-click="stop_batch"
                data-confirm={
                  gettext(
                    "Stop the running batch? It stops once the current file (or chunk) finishes. What has been ingested and generated so far is kept, and the rest is picked up by the next batch."
                  )
                }
                class="text-xs px-3.5 py-2 rounded-lg bg-red-600 hover:bg-red-700 text-white font-medium shadow-sm flex items-center gap-1.5 transition"
              >
                <.icon name="hero-stop" class="w-4 h-4" /> {gettext("Stop batch")}
              </button>
            <% end %>
          </div>

          <div :if={@scope == :app && !@running_run} class="flex flex-wrap items-center gap-2">
            <%!-- The newest run ended early and work is left: resuming is the obvious next step
                  (F-342), so it leads here too, not only in the run details below. --%>
            <button
              :if={resumable?(@runs, @remaining)}
              id="resume-header-btn"
              phx-click="trigger_batch"
              phx-value-kind="full"
              data-confirm={
                if(@current_mode == :daytime,
                  do:
                    gettext(
                      "It is currently business hours. A batch with QA generation occupies the generation model for a long time, and chat falls back to source search only (mostly keywords) meanwhile. Resume from where it stopped?"
                    ),
                  else: gettext("Resume from where it stopped?")
                )
              }
              title={
                gettext(
                  "The previous batch did not finish. Only the rest is processed (finished parts are not redone)."
                )
              }
              class="text-xs px-3.5 py-2 rounded-lg bg-amber-500 hover:bg-amber-600 text-white font-medium shadow-sm flex items-center gap-1.5 transition"
            >
              <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext(
                "Resume (%{count} chunks left)",
                count: @remaining.chunks
              )}
            </button>
            <%!-- Ingest only (spec 6.3.8 F-331): sync + indexing, no QA generation, so the
                  local model stays free for chat. The safe default for daytime runs. --%>
            <button
              id="trigger-ingest-btn"
              phx-click="trigger_batch"
              phx-value-kind="ingest_only"
              title={
                gettext(
                  "Only syncs Drive and runs ingestion (text extraction and embedding). No QA generation, so chat works as usual while it runs."
                )
              }
              class="text-xs px-3.5 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium shadow-sm flex items-center gap-1.5 transition"
            >
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("Run ingestion only")}
            </button>
            <button
              id="trigger-batch-btn"
              phx-click="trigger_batch"
              phx-value-kind="full"
              data-confirm={
                if(@current_mode == :daytime,
                  do:
                    gettext(
                      "It is currently business hours. A batch with QA generation occupies the generation model for a long time, and chat falls back to source search only (mostly keywords) meanwhile. \"Run ingestion only\" is usually enough. Run it anyway?"
                    ),
                  else: gettext("Run the batch (with QA generation) manually?")
                )
              }
              class="text-xs px-3.5 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium flex items-center gap-1.5 transition"
            >
              <.icon name="hero-play" class="w-4 h-4" /> {gettext("Full run (with QA generation)")}
            </button>
          </div>
        </div>

        <%!-- An API key not registered yet (spec F-343): say so, and what it holds back --%>
        <% missing_embed = @scope == :app && AskDrive.LLM.missing_api_key(:embedding, @setting) %>
        <% missing_gen = @scope == :app && AskDrive.LLM.missing_api_key(:generation, @setting) %>
        <div
          :if={missing_embed || missing_gen}
          id="missing-api-key"
          class="p-3 rounded-xl bg-amber-50 dark:bg-amber-950/40 border border-amber-200 dark:border-amber-900 text-xs text-amber-900 dark:text-amber-100 space-y-1"
        >
          <p class="font-semibold flex items-center gap-1.5">
            <.icon name="hero-key" class="w-4 h-4" /> {gettext("API key not registered")}
          </p>
          <p :if={missing_embed}>
            {gettext(
              "There is no API key for embedding (%{provider}), so the nightly batch (document ingestion) does not run. Chat is limited to keyword search over the source text.",
              provider: missing_embed
            )}
          </p>
          <p :if={!missing_embed && missing_gen}>
            {gettext(
              "There is no API key for answer generation (%{provider}), so the nightly batch only ingests documents and does not generate QA pairs.",
              provider: missing_gen
            )}
          </p>
          <p>
            {gettext("When the key is issued, open the ")}<.link
              patch={"/#{@app.slug}/admin?tab=settings"}
              class="underline font-medium"
            >{gettext("Settings tab")}</.link>{gettext(" and register it there.")}
          </p>
        </div>

        <%!-- Tab Navigation (per scope, spec 6.11) --%>
        <div class="flex border-b border-zinc-200 dark:border-zinc-800 gap-6 text-sm font-medium">
          <button
            :for={{tab, label} <- tabs(@scope)}
            phx-click="select_tab"
            phx-value-tab={tab}
            id={"tab-#{tab}"}
            class={[
              "pb-3 border-b-2 transition",
              if(@current_tab == tab,
                do: "border-indigo-600 text-indigo-600 dark:text-indigo-400",
                else: "border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              )
            ]}
          >
            {label}
          </button>
        </div>

        <%!-- Tab 1: Overview & Batch Status --%>
        <%= if @current_tab == "overview" do %>
          <div class="space-y-6">
            <%!-- KPI Cards --%>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">{gettext("Synced documents")}</p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {@total_docs}
                </p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">{gettext("Total chunks")}</p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {@total_chunks}
                </p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">{gettext("Active QA pairs (Tier 1)")}</p>
                <p class="text-2xl font-bold text-emerald-600 dark:text-emerald-400 mt-1">
                  {@active_qas}
                </p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">
                  {gettext("Stale QA pairs (awaiting regeneration)")}
                </p>
                <p class="text-2xl font-bold text-amber-600 dark:text-amber-400 mt-1">
                  {@stale_qas}
                </p>
              </div>
            </div>

            <%!-- Nightly trigger status and batch history (spec F-338) --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-clock" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "Nightly batch schedule and history"
                  )}
                </h2>
                <span class="text-xs text-zinc-500">
                  {gettext(
                    "Nightly window: daily %{start}:00 to %{finish}:00 the next day · cutoff %{deadline}:00 (local time of this PC)",
                    start: pad2(elem(@auto_status.window, 0)),
                    finish: pad2(elem(@auto_status.window, 1)),
                    deadline: pad2(@auto_status.deadline_hour)
                  )}
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

                    :off ->
                      "bg-zinc-50 border-zinc-200 text-zinc-700 dark:bg-zinc-900 dark:border-zinc-800 dark:text-zinc-300"
                  end
                ]}
              >
                <%= case @auto_status.state do %>
                  <% :off -> %>
                    <div class="flex flex-wrap items-center justify-between gap-2">
                      <span>
                        {gettext("Automatic nightly runs for this desk are ")}<strong>{gettext("off")}</strong>{gettext(
                          " (still being set up). \"Run now\" and \"Ingest only\" can be run manually."
                        )}
                        <span :if={@setup_looks_done?} id="auto-batch-ready-hint">
                          {gettext(
                            "Google Drive and AI are set up. Turn on automatic runs when you are ready."
                          )}
                        </span>
                      </span>
                      <button
                        id="auto-batch-on-btn"
                        phx-click="set_auto_batch"
                        phx-value-on="true"
                        class="px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium"
                      >
                        {gettext("Turn on automatic runs")}
                      </button>
                    </div>
                  <% :running -> %>
                    {gettext("Batch is running.")}
                    <span :if={@running_progress}>
                      {gettext("Overall estimate %{percent}%", percent: @running_progress.overall)}{if @running_progress.remaining_seconds,
                        do:
                          gettext("(%{eta} left)",
                            eta: eta_label(@running_progress.remaining_seconds)
                          )} ・ {gettext("Step %{step}/%{steps} \"%{label}\"",
                        step: @running_progress.step,
                        steps: @running_progress.steps,
                        label: @running_progress.label
                      )}{if @running_progress.total > 0,
                        do: " #{@running_progress.done} / #{@running_progress.total}"}
                    </span>
                  <% :done -> %>
                    {gettext(
                      "The nightly window of %{date} has already run (#%{id} · %{trigger} · started %{time} · %{status}). Next automatic run: %{next}",
                      date: Calendar.strftime(@auto_status.window_start, "%-m/%-d"),
                      id: @auto_status.run.id,
                      trigger: trigger_label(@auto_status.run.trigger),
                      time: AskDrive.Clock.format(@auto_status.run.started_at, "%H:%M"),
                      status: status_label(@auto_status.run.status),
                      next: Calendar.strftime(@auto_status.next_start, "%-m/%-d %H:%M")
                    )}
                  <% :due -> %>
                    {gettext(
                      "Within the nightly window, and this window has not run yet. It will start automatically within a minute."
                    )}
                  <% :missed -> %>
                    {gettext(
                      "No automatic run was recorded in the nightly window of %{date} (runs cut short by a restart are not counted, and manual runs do not replace automatic ones). Next automatic run: %{next}",
                      date: Calendar.strftime(@auto_status.window_start, "%-m/%-d"),
                      next: Calendar.strftime(@auto_status.next_start, "%-m/%-d %H:%M")
                    )}
                <% end %>
              </div>

              <p
                :if={@scope == :app and @auto_status.state != :off and @setting.auto_batch_enabled}
                class="text-[11px] text-zinc-500"
              >
                {gettext("Automatic nightly runs: on ·")}
                <button
                  id="auto-batch-off-btn"
                  phx-click="set_auto_batch"
                  phx-value-on="false"
                  data-confirm={
                    gettext(
                      "Turn off automatic nightly runs for this desk? (Manual runs remain available.)"
                    )
                  }
                  class="underline hover:text-zinc-800 dark:hover:text-zinc-200"
                >
                  {gettext("Turn off")}
                </button>
              </p>

              <%= if @runs == [] do %>
                <p class="text-xs text-zinc-500">{gettext("No batch runs yet.")}</p>
              <% else %>
                <div class="overflow-x-auto">
                  <table
                    id="batch-history"
                    class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                  >
                    <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                      <tr>
                        <th class="py-2 px-2">#</th>
                        <th class="py-2 px-2">{gettext("Started")}</th>
                        <th class="py-2 px-2 text-right">{gettext("Duration")}</th>
                        <th class="py-2 px-2">{gettext("Trigger")}</th>
                        <th class="py-2 px-2">{gettext("Type")}</th>
                        <th class="py-2 px-2">{gettext("Status")}</th>
                        <th class="py-2 px-2 text-right">
                          {gettext("Ingested (documents / chunks)")}
                        </th>
                        <th class="py-2 px-2 text-right">{gettext("Failed")}</th>
                        <th class="py-2 px-2 text-right">{gettext("QA generated")}</th>
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
                          {if run.kind == "ingest_only",
                            do: gettext("Ingest only"),
                            else: gettext("Full")}
                        </td>
                        <td class="py-2 px-2 whitespace-nowrap">
                          <span class={[
                            "px-2 py-0.5 rounded-full text-[10px] font-medium",
                            status_class(run.status)
                          ]}>
                            {status_label(run.status)}
                          </span>
                          <span
                            :if={
                              run.status == "running" && @running_run && run.id == @running_run.id &&
                                @running_progress
                            }
                            class="ml-1 font-mono text-blue-700 dark:text-blue-300"
                          >
                            {@running_progress.overall}%
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
                  {gettext(
                    "Click a row to show that batch's details (phase breakdown and per-file log) in \"Batch run status\" below."
                  )}
                </p>
              <% end %>
            </div>

            <%!-- Latest Batch Run Card --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex items-center justify-between">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "Batch run status"
                  )}
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

                      "stopped" ->
                        "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300 border border-zinc-200/50"

                      "skipped" ->
                        "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50"

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
                    {gettext("Ingest only")}
                  </span>
                </div>
              </div>

              <%= if @latest_run do %>
                <div class="grid grid-cols-2 sm:grid-cols-5 gap-4 text-xs text-zinc-600 dark:text-zinc-400">
                  <div>
                    <span class="text-zinc-400 block">{gettext("Started at")}</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {AskDrive.Clock.format(@latest_run.started_at, "%Y-%m-%d %H:%M:%S")}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">{gettext("Finished at")}</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {if @latest_run.finished_at,
                        do: AskDrive.Clock.format(@latest_run.finished_at, "%Y-%m-%d %H:%M:%S"),
                        else: gettext("Running...")}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">{gettext(
                      "Ingested (successful documents / chunks)"
                    )}</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {gettext("%{documents} documents / %{chunks} chunks",
                        documents: count_logs(@item_logs, "embed_chunks", "indexed"),
                        chunks: sum_chunks(@item_logs)
                      )}
                      <span
                        :if={count_logs(@item_logs, "failed") > 0}
                        class="text-red-600 dark:text-red-400"
                      >
                        {gettext("(%{count} failed)", count: count_logs(@item_logs, "failed"))}
                      </span>
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">{gettext(
                      "QA generation (chunks processed / QA generated)"
                    )}</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {gettext("%{chunks} chunks / %{qas} QA",
                        chunks: @latest_run.chunks_processed,
                        qas: @latest_run.qa_generated
                      )}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">{gettext("Unanswered resolved / queue left")}</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {gettext("%{resolved} resolved / %{queued} queued",
                        resolved: @latest_run.questions_resolved,
                        queued: @latest_run.queue_remaining
                      )}
                    </span>
                  </div>
                </div>

                <%!-- Why a run failed (batch_runs.error): the message and where it happened --%>
                <div
                  :if={@latest_run.status == "failed" && @latest_run.error}
                  id="batch-error"
                  class="p-3 rounded-lg bg-red-50 dark:bg-red-950/40 border border-red-200 dark:border-red-900 space-y-1"
                >
                  <p class="text-xs font-semibold text-red-800 dark:text-red-200">
                    {gettext("Cause of failure (error)")}
                  </p>
                  <pre class="text-[11px] leading-relaxed text-red-900 dark:text-red-100 whitespace-pre-wrap break-all max-h-60 overflow-y-auto">{@latest_run.error}</pre>
                </div>

                <%!-- A note on a run that didn't do everything (spec F-343): skipped for a missing
                      API key, or indexed without generating QA --%>
                <div
                  :if={@latest_run.status != "failed" && @latest_run.error}
                  id="batch-note"
                  class="p-3 rounded-lg bg-amber-50 dark:bg-amber-950/40 border border-amber-200 dark:border-amber-900 text-xs text-amber-900 dark:text-amber-100"
                >
                  {@latest_run.error}
                </div>

                <%!-- Resume (spec F-342): a re-run continues from the data — only what is left is
                      done — so a failed, stopped or cut-off run is simply run again. --%>
                <div
                  :if={
                    @scope == :app && !@running_run &&
                      @latest_run.status in ["failed", "stopped", "aborted", "deadline_reached"]
                  }
                  id="batch-resume"
                  class="p-3 rounded-lg bg-indigo-50/70 dark:bg-indigo-950/30 border border-indigo-200/70 dark:border-indigo-900 space-y-2 text-xs"
                >
                  <p class="font-semibold text-indigo-900 dark:text-indigo-200">
                    {gettext("Resume")}
                  </p>
                  <p class="text-zinc-700 dark:text-zinc-300">
                    {gettext(
                      "Left: %{documents} documents to ingest · %{chunks} chunks without QA · %{questions} questions to embed",
                      documents: @remaining.documents,
                      chunks: @remaining.chunks,
                      questions: @remaining.questions
                    )}
                    <span :if={@remaining.given_up > 0} class="text-amber-700 dark:text-amber-300">
                      {gettext("(%{count} chunks excluded after 3 failures)",
                        count: @remaining.given_up
                      )}
                    </span>
                  </p>
                  <p class="text-zinc-500">
                    {gettext(
                      "Documents already ingested and chunks that already have QA are not redone. Chunks that failed last time go last."
                    )}
                  </p>
                  <button
                    id="resume-batch-btn"
                    phx-click="trigger_batch"
                    phx-value-kind="full"
                    data-confirm={
                      if(@current_mode == :daytime,
                        do:
                          gettext(
                            "It is currently business hours. A batch with QA generation occupies the generation model for a long time, and chat falls back to source search only (mostly keywords) meanwhile. Resume from where it stopped?"
                          ),
                        else: gettext("Resume from where it stopped?")
                      )
                    }
                    class="px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium shadow-sm inline-flex items-center gap-1.5 transition"
                  >
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Resume")}
                  </button>
                </div>

                <%!-- Progress of the run (spec F-340): overall, the current step, and the item --%>
                <div
                  :if={
                    @selected_progress &&
                      @latest_run.status in ["running", "waiting", "aborted", "failed", "stopped"]
                  }
                  id="batch-progress"
                  class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3"
                >
                  <h3 class="text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                    {case @latest_run.status do
                      "running" ->
                        gettext("Progress")

                      "waiting" ->
                        gettext(
                          "Progress (QA pairs are generated once the other desks finish ingestion)"
                        )

                      _ ->
                        gettext("Where it stopped")
                    end}
                  </h3>
                  <div>
                    <div class="flex items-baseline justify-between text-xs text-zinc-600 dark:text-zinc-400">
                      <span>
                        {gettext("Overall estimate")}<span
                          :if={@latest_run.status == "running"}
                          id="batch-progress-basis"
                          class="text-zinc-500"
                        >{if @selected_progress.basis == :time,
                          do:
                            gettext(
                              "(based on expected processing time, estimated from recent batches' step durations and this step's pace)"
                            ),
                          else:
                            gettext(
                              "(based on fixed per-step ratios; switches to processing time once enough durations are recorded)"
                            )}</span>
                      </span>
                      <span class="font-mono text-base font-semibold text-zinc-900 dark:text-zinc-100">
                        {@selected_progress.overall}%
                      </span>
                    </div>
                    <p
                      :if={@latest_run.status == "running" && @selected_progress.remaining_seconds}
                      id="batch-progress-remaining"
                      class="mt-0.5 text-right text-[11px] text-zinc-500"
                    >
                      {gettext("%{eta} left overall",
                        eta: eta_label(@selected_progress.remaining_seconds)
                      )}
                    </p>
                    <div class="mt-1 h-2.5 rounded-full bg-zinc-200 dark:bg-zinc-800 overflow-hidden">
                      <div
                        class="h-full rounded-full bg-indigo-600 transition-all duration-700"
                        style={"width: #{@selected_progress.overall}%"}
                      >
                      </div>
                    </div>
                  </div>
                  <div class="p-3 rounded-lg bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800/80 space-y-1.5 text-xs">
                    <div class="flex flex-wrap items-baseline justify-between gap-2">
                      <span class="font-medium text-zinc-800 dark:text-zinc-200">
                        {gettext("Step %{step}/%{steps}: %{label}",
                          step: @selected_progress.step,
                          steps: @selected_progress.steps,
                          label: @selected_progress.label
                        )}
                      </span>
                      <span
                        :if={@selected_progress.total > 0}
                        class="font-mono text-zinc-600 dark:text-zinc-400"
                      >
                        {gettext("%{done} / %{total} (%{percent}%)",
                          done: @selected_progress.done,
                          total: @selected_progress.total,
                          percent: @selected_progress.percent
                        )}
                      </span>
                    </div>
                    <div
                      :if={@selected_progress.total > 0}
                      class="h-1.5 rounded-full bg-zinc-200 dark:bg-zinc-800 overflow-hidden"
                    >
                      <div
                        class="h-full rounded-full bg-blue-500 transition-all duration-700"
                        style={"width: #{@selected_progress.percent}%"}
                      >
                      </div>
                    </div>
                    <p
                      :if={@selected_progress.item}
                      class="text-zinc-600 dark:text-zinc-400 break-all"
                    >
                      {if @latest_run.status == "running",
                        do: gettext("Processing"),
                        else: gettext("Last item processed")}: {@selected_progress.item}
                      <span :if={@selected_progress.detail} class="text-zinc-500">
                        — {@selected_progress.detail}
                      </span>
                    </p>
                    <p
                      :if={!@selected_progress.item && @selected_progress.detail}
                      class="text-zinc-600 dark:text-zinc-400"
                    >
                      {@selected_progress.detail}
                    </p>
                    <p :if={@latest_run.status == "running"} class="text-zinc-500">
                      {gettext("Elapsed in this step: %{time}",
                        time: format_seconds(@selected_progress.elapsed_seconds)
                      )}<span :if={@selected_progress.eta_seconds}>{gettext(
                        " · %{eta} left (estimated from the pace so far)",
                        eta: eta_label(@selected_progress.eta_seconds)
                      )}</span>
                    </p>
                    <p
                      :if={@selected_progress[:past_deadline]}
                      class="text-amber-700 dark:text-amber-300"
                    >
                      {gettext(
                        "At this pace, not everything will finish by the cutoff (%{deadline}). The rest will be generated by the next batch.",
                        deadline: @selected_progress.past_deadline
                      )}
                    </p>
                  </div>
                  <p class="text-[11px] text-zinc-400">
                    {gettext(
                      "The overall % is an estimate weighted by step (ingestion and QA generation make up most of it). This screen refreshes every 5 seconds."
                    )}
                  </p>
                </div>

                <%!-- Phase Breakdown List --%>
                <div class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-2">
                  <h3 class="text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                    {gettext("Phase breakdown")}
                  </h3>
                  <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2 text-xs">
                    <%= for stat <- @latest_run.phase_stats do %>
                      <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800/80 flex items-center justify-between">
                        <span class="font-medium text-zinc-700 dark:text-zinc-300">
                          {Progress.label(stat.phase_name)}
                        </span>
                        <div class="text-right text-zinc-500">
                          <span>{gettext("%{count}s", count: stat.duration_seconds)}</span>
                          <span class="text-[10px] ml-1 text-zinc-400">{gettext("(%{count} items)",
                            count: stat.items_count
                          )}</span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>

                <%!-- Chunks given up after 3 failed generations (spec F-342) --%>
                <div
                  :if={@scope == :app && @given_up_chunks != []}
                  id="given-up-chunks"
                  class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-2"
                >
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <h3 class="text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                      {gettext("Chunks QA could not be generated for (failed 3 times · %{count})",
                        count: @remaining.given_up
                      )}
                    </h3>
                    <button
                      id="retry-given-up-btn"
                      phx-click="retry_given_up"
                      class="text-xs px-3 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium inline-flex items-center gap-1.5 transition"
                    >
                      <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext(
                        "Return to generation"
                      )}
                    </button>
                  </div>
                  <p class="text-[11px] text-zinc-400">
                    {gettext(
                      "The batch skips these (so it does not spend time on the same chunks every night). Return them after changing the model or fixing the cause. When a document is updated, its changed chunks return automatically."
                    )}
                  </p>
                  <div class="overflow-x-auto max-h-60 overflow-y-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                        <tr :for={chunk <- @given_up_chunks}>
                          <td class="py-1.5 px-2 break-all">
                            {(chunk.document && (chunk.document.path || chunk.document.name)) || "—"}{gettext(
                              " (chunk %{number})",
                              number: chunk.position + 1
                            )}
                          </td>
                          <td class="py-1.5 px-2 text-red-700 dark:text-red-300 break-all">
                            {chunk.qa_error}
                          </td>
                          <td class="py-1.5 px-2 font-mono whitespace-nowrap">
                            {chunk.qa_attempted_at &&
                              AskDrive.Clock.format(chunk.qa_attempted_at, "%m/%d %H:%M")}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </div>

                <%!-- Per-file log (spec 6.3.5): what happened to each Drive file, and why --%>
                <div class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-2">
                  <h3 class="text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                    {gettext("Per-file log (%{count} · failures first)", count: length(@item_logs))}
                  </h3>
                  <%= if @item_logs == [] do %>
                    <p class="text-xs text-zinc-500">
                      {gettext(
                        "No per-file log for this batch (batches run before v0.0.27 did not record one)."
                      )}
                    </p>
                  <% else %>
                    <div class="overflow-x-auto max-h-[28rem] overflow-y-auto">
                      <table
                        id="batch-item-logs"
                        class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                      >
                        <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800 sticky top-0 bg-white dark:bg-zinc-900">
                          <tr>
                            <th class="py-2 px-2">{gettext("Phase")}</th>
                            <th class="py-2 px-2">{gettext("Result")}</th>
                            <th class="py-2 px-2">{gettext("File")}</th>
                            <th class="py-2 px-2 text-right">{gettext("Chunks")}</th>
                            <th class="py-2 px-2 text-right">{gettext("Time")}</th>
                            <th class="py-2 px-2">{gettext("Details")}</th>
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
                <p class="text-xs text-zinc-500">{gettext("No nightly batch runs yet.")}</p>
              <% end %>
            </div>

            <%!-- System & Model Health --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-server" class="w-5 h-5 text-indigo-600" /> {gettext(
                  "System and inference status"
                )}
              </h2>
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-4 text-xs">
                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">SQLite sqlite-vec</span>
                  <span class="font-semibold text-emerald-600 mt-1 block">
                    <%= case @health.sqlite_vec do %>
                      <% {:ok, v} -> %>
                        {gettext("Enabled (v%{version})", version: v)}
                      <% {:error, err} -> %>
                        <span class="text-red-600">{gettext("Disabled: %{error}", error: err)}</span>
                    <% end %>
                  </span>
                </div>

                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">
                    {gettext("Answer generation (%{provider})",
                      provider: LLM.label(@generation_provider)
                    )}
                  </span>
                  <span class="font-semibold text-emerald-600 mt-1 block">
                    <%= case @health.llm_generation do %>
                      <% {:ok, info} -> %>
                        {gettext("Connected (%{info})", info: info)}
                      <% {:error, err} -> %>
                        <span class="text-red-600">{gettext("Not connected: %{error}", error: err)}</span>
                    <% end %>
                  </span>
                  <span class="text-[10px] text-zinc-400 mt-0.5 block">
                    {LLM.generation_model(@setting)}{if LLM.cloud_mode?(@setting),
                      do: gettext("(cloud)")}
                  </span>
                </div>

                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">
                    {gettext("Embedding (%{provider})", provider: LLM.label(@embedding_provider))}
                  </span>
                  <span class="font-semibold text-emerald-600 mt-1 block">
                    <%= case @health.llm_embedding do %>
                      <% {:ok, info} -> %>
                        {gettext("Connected (%{info})", info: info)}
                      <% {:error, err} -> %>
                        <span class="text-red-600">{gettext("Not connected: %{error}", error: err)}</span>
                    <% end %>
                  </span>
                  <span class="text-[10px] text-zinc-400 mt-0.5 block">
                    {@setting.embed_model} / {gettext("%{count} dimensions",
                      count: @setting.embedding_dim
                    )}
                  </span>
                </div>

                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">{gettext("pdftotext (PDF extraction)")}</span>
                  <span class="font-semibold mt-1 block">
                    {if @health.pdftotext == :ok,
                      do: gettext("Available"),
                      else: gettext("Not installed (poppler)")}
                  </span>
                </div>

                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">{gettext("pandoc (Office extraction)")}</span>
                  <span class="font-semibold mt-1 block">
                    {if @health.pandoc == :ok,
                      do: gettext("Available"),
                      else: gettext("Not installed (pandoc)")}
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
                  {gettext("Unanswered questions (top priority in the next nightly batch)")}
                </span>
                <span class="text-xs font-normal text-zinc-500">
                  {gettext("%{count} items", count: length(@unresolved_questions))}
                </span>
              </h2>

              <%= if @unresolved_questions == [] do %>
                <p class="text-xs text-zinc-500 py-4 text-center">
                  {gettext("No unresolved questions right now.")}
                </p>
              <% else %>
                <div class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                  <%= for q <- @unresolved_questions do %>
                    <div class="py-3 flex items-start justify-between gap-4 text-xs">
                      <div>
                        <p class="font-medium text-zinc-900 dark:text-zinc-100">{q.question}</p>
                        <p class="text-[11px] text-zinc-400 mt-0.5">
                          {gettext("Reached: Tier %{tier} · Asked: %{time}",
                            tier: q.tier_reached,
                            time: AskDrive.Clock.format(q.asked_at, "%Y-%m-%d %H:%M")
                          )}
                        </p>
                      </div>
                      <span class="text-[10px] px-2 py-0.5 rounded-full bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50">
                        {gettext("Priority 1")}
                      </span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-check-badge" class="w-5 h-5 text-emerald-600" />
                {gettext("Recently resolved questions (from last night's batch)")}
              </h2>

              <%= if @resolved_questions == [] do %>
                <p class="text-xs text-zinc-500 py-4 text-center">
                  {gettext("No resolved questions yet.")}
                </p>
              <% else %>
                <div class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                  <%= for q <- @resolved_questions do %>
                    <div class="py-3 space-y-1.5 text-xs">
                      <div class="flex items-center justify-between">
                        <p class="font-medium text-zinc-900 dark:text-zinc-100">{q.question}</p>
                        <span class="text-[10px] text-zinc-400">
                          {gettext("Resolved: %{time}",
                            time: AskDrive.Clock.format(q.resolved_at, "%Y-%m-%d %H:%M")
                          )}
                        </span>
                      </div>
                      <%= if q.resolved_qa do %>
                        <div class="p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-950 text-zinc-600 dark:text-zinc-400 text-[11px]">
                          <span class="font-semibold text-emerald-600">{gettext("Generated answer:")}</span>
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
              <span>{gettext("Documents for ingestion")}</span>
              <span class="text-xs font-normal text-zinc-500">
                {gettext("%{count} in total", count: length(@documents))}
              </span>
            </h2>

            <%= if @documents == [] do %>
              <p class="text-xs text-zinc-500 py-8 text-center">
                {gettext("No synced documents yet. Connect Google and sync Drive.")}
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                  <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-3 px-2">{gettext("Document name")}</th>
                      <th class="py-3 px-2">{gettext("Status")}</th>
                      <th class="py-3 px-2">{gettext("File type")}</th>
                      <th class="py-3 px-2 text-right">{gettext("Token efficiency")}</th>
                      <th class="py-3 px-2">{gettext("Last synced")}</th>
                      <th class="py-3 px-2 text-right">Drive</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                    <%= for doc <- @documents do %>
                      <% eff =
                        Enum.find(@data_efficiency.doc_stats, fn s -> s.document.id == doc.id end) %>
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
                        <td class="py-3 px-2 text-right">
                          <%= if eff do %>
                            <span class={[
                              "px-2 py-0.5 rounded-full text-[10px] font-medium inline-block",
                              cond do
                                eff.score_level == :excellent ->
                                  "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

                                eff.score_level == :good ->
                                  "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300"

                                eff.score_level == :fair ->
                                  "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

                                eff.score_level == :poor ->
                                  "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

                                true ->
                                  "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"
                              end
                            ]}>
                              {eff.score_rating}
                            </span>
                            <span class="text-[10px] text-zinc-400 block mt-0.5">
                              {eff.total_tokens} tokens
                            </span>
                          <% else %>
                            <span class="text-zinc-400">—</span>
                          <% end %>
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
                              {gettext("Open")}
                              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
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

        <%!-- Platform: apps (spec 6.11) --%>
        <%= if @current_tab == "apps" do %>
          <div class="space-y-6">
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 flex-1">
                  <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                    <.icon name="hero-squares-2x2" class="w-5 h-5 text-indigo-600" /> {gettext(
                      "Desks (apps)"
                    )}
                  </h2>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    {gettext(
                      "Each desk has its own Google Drive folder, API keys such as Gemini (so costs can be split), search index, QA pairs, question log and nightly batch history. Each desk's data is stored in a separate database and never mixed."
                    )}
                  </p>
                </div>
                <button
                  :if={not @show_new_app}
                  type="button"
                  id="show-new-app-btn"
                  phx-click="toggle_new_app"
                  class="shrink-0 inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium shadow-sm transition"
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add desk")}
                </button>
              </div>

              <%!-- New app, right above the list (spec 6.11): validated as you type, with the
                    URL the app will get. --%>
              <div
                :if={@show_new_app}
                id="new-app-panel"
                class="p-4 rounded-xl border-2 border-indigo-200 dark:border-indigo-900 bg-indigo-50/40 dark:bg-indigo-950/20 space-y-3"
              >
                <h3 class="font-semibold text-sm text-zinc-900 dark:text-zinc-100">
                  {gettext("New desk")}
                </h3>
                <.form
                  for={@app_form}
                  id="new-app-form"
                  phx-change="validate_app"
                  phx-submit="create_app"
                  class="grid grid-cols-1 sm:grid-cols-3 gap-3"
                >
                  <.input
                    field={@app_form[:name]}
                    type="text"
                    label={gettext("Desk name (e.g. HR)")}
                    phx-debounce="300"
                  />
                  <.input
                    field={@app_form[:slug]}
                    type="text"
                    label={gettext("URL name (lowercase letters, digits, hyphens)")}
                    placeholder="hr"
                    phx-debounce="300"
                  />
                  <.input
                    field={@app_form[:description]}
                    type="text"
                    label={gettext("Description (optional, shown in the desk list)")}
                  />
                  <%!-- required (F-1114): an app always has an administrator --%>
                  <label class="sm:col-span-3 text-xs space-y-1">
                    <span class="block font-medium text-zinc-700 dark:text-zinc-300">
                      {gettext(
                        "Email addresses of the desk administrators (required; separate multiple with commas)"
                      )}
                    </span>
                    <.email_input
                      id="new-app-admin-emails"
                      name="app[admin_emails]"
                      ac={@ac}
                      placeholder={
                        if @setting.allowed_domain,
                          do: "name@#{@setting.allowed_domain}",
                          else: "name@company.com"
                      }
                    />
                    <span class="block text-zinc-500">
                      {gettext(
                        "Desk administrators configure the desk (Drive, API keys, etc.). Platform administrators cannot open a desk's admin screen."
                      )}
                    </span>
                  </label>
                  <p class="sm:col-span-3 text-xs text-zinc-600 dark:text-zinc-400">
                    {gettext("Chat URL:")}
                    <span id="new-app-url" class="font-mono text-indigo-700 dark:text-indigo-300">
                      /{slug_preview(@app_form)}
                    </span>
                    {gettext("· Admin screen:")}
                    <span class="font-mono">/{slug_preview(@app_form)}/admin</span>
                  </p>
                  <div class="sm:col-span-3 flex flex-wrap items-center gap-2">
                    <button
                      type="submit"
                      id="create-app-btn"
                      class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium"
                    >
                      {gettext("Create desk")}
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_new_app"
                      class="px-4 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs"
                    >
                      {gettext("Cancel")}
                    </button>
                    <span class="text-[11px] text-zinc-500">
                      {gettext(
                        "AI settings are copied from the first desk. Set up Google Drive and API keys after creating it."
                      )}
                    </span>
                  </div>
                </.form>
              </div>

              <div
                :if={@last_created_app}
                id="app-created-next"
                class="text-xs rounded-lg border border-emerald-200 bg-emerald-50 dark:bg-emerald-950/40 dark:border-emerald-900 px-3 py-2 flex flex-wrap items-center gap-2"
              >
                <span class="text-emerald-800 dark:text-emerald-200">
                  {gettext(
                    "Created desk \"%{name}\" (/%{slug}). Next, set up the Google Drive folder and authentication, and API keys if needed.",
                    name: @last_created_app.name,
                    slug: @last_created_app.slug
                  )}
                </span>
                <a
                  href={"/" <> @last_created_app.slug <> "/admin?tab=settings"}
                  id="open-new-app-settings"
                  class="px-3 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white font-medium"
                >
                  {gettext("Open desk settings →")}
                </a>
              </div>

              <div class="overflow-x-auto">
                <table
                  id="apps-table"
                  class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                >
                  <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-2 px-2">{gettext("Desk name / description")}</th>
                      <th class="py-2 px-2">URL</th>
                      <th class="py-2 px-2 text-right">{gettext("Documents / chunks")}</th>
                      <th class="py-2 px-2">Drive</th>
                      <th class="py-2 px-2">{gettext("Last batch")}</th>
                      <th class="py-2 px-2"></th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                    <%= for app <- @apps do %>
                      <tr id={"app-row-#{app.slug}"}>
                        <td class="py-2 px-2">
                          <form :if={app.id} phx-submit="update_app" class="space-y-1">
                            <input type="hidden" name="app_id" value={app.id} />
                            <input
                              type="text"
                              name="name"
                              value={app.name}
                              class="w-44 px-2 py-1 rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-xs font-medium"
                            />
                            <input
                              type="text"
                              name="description"
                              value={app.description}
                              placeholder={gettext("Description (shown on the portal)")}
                              class="w-full px-2 py-1 rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 text-[11px]"
                            />
                            <button type="submit" class="text-[11px] underline text-indigo-600">
                              {gettext("Save")}
                            </button>
                          </form>
                          <span :if={is_nil(app.id)} class="font-medium">{app.name}</span>
                        </td>
                        <td class="py-2 px-2 font-mono whitespace-nowrap">
                          <a href={"/" <> app.slug} class="text-indigo-600 underline">/{app.slug}</a>
                          <a href={"/" <> app.slug <> "/admin"} class="ml-2 text-zinc-500 underline">
                            {gettext("Admin")}
                          </a>
                        </td>
                        <% sum = Map.get(@app_summaries, app.slug, %{}) %>
                        <td class="py-2 px-2 text-right font-mono">
                          {sum[:docs] || 0} / {sum[:chunks] || 0}
                        </td>
                        <td class="py-2 px-2 whitespace-nowrap">
                          <%= if sum[:drive?] do %>
                            {gettext("Set")}
                          <% else %>
                            <a
                              href={"/" <> app.slug <> "/admin?tab=settings"}
                              class="text-amber-700 dark:text-amber-300 underline"
                            >
                              {gettext("Not set (set up)")}
                            </a>
                          <% end %>
                        </td>
                        <td class="py-2 px-2 whitespace-nowrap">
                          <%= if run = sum[:last_run] do %>
                            {AskDrive.Clock.format(run.started_at, "%m/%d %H:%M")} {status_label(
                              run.status
                            )}
                          <% else %>
                            —
                          <% end %>
                          <span
                            :if={sum[:auto?] == false}
                            id={"app-auto-off-#{app.slug}"}
                            class="ml-1 px-1.5 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-400 text-[10px]"
                          >
                            {gettext("Auto-run: off (being set up)")}
                          </span>
                        </td>
                        <td class="py-2 px-2 text-right whitespace-nowrap space-x-2">
                          <%!-- the app's administrators (F-1114); none = nobody can administer it --%>
                          <span
                            id={"app-admins-#{app.slug}"}
                            class={[
                              "text-[11px]",
                              if(@app_admins[app.slug] == [],
                                do: "text-red-600 font-medium",
                                else: "text-zinc-500"
                              )
                            ]}
                          >
                            {case @app_admins[app.slug] || [] do
                              [] ->
                                gettext("No administrator (assign one in User management)")

                              admins ->
                                gettext("Administrators: %{emails}",
                                  emails: Enum.map_join(admins, gettext(", "), & &1.email)
                                )
                            end}
                          </span>
                          <button
                            :if={not app.primary and app.id}
                            type="button"
                            phx-click="delete_app"
                            phx-value-id={app.id}
                            data-confirm={
                              gettext(
                                "Delete desk \"%{name}\"? Its chat and admin screen will stop working (the database file is kept under a new name). Continue?",
                                name: app.name
                              )
                            }
                            class="text-[11px] text-red-600 underline"
                          >
                            {gettext("Delete")}
                          </button>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Tab 4: User Management --%>
        <%= if @current_tab == "users" do %>
          <div class="space-y-6">
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                    <.icon name="hero-users" class="w-5 h-5 text-indigo-600" /> {gettext(
                      "Registered users"
                    )}
                  </h2>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    {gettext(
                      "Users are registered automatically on first sign-in and all start as regular users. Only accounts marked"
                    )}
                    <strong>{gettext("\"Can elevate\"")}</strong>
                    {gettext(
                      "(platform administrators) can verify their identity and temporarily enter platform administration."
                    )}
                  </p>
                </div>
                <span class="text-xs text-zinc-500 shrink-0">{gettext("%{count} users in total",
                  count: length(@users)
                )}</span>
              </div>

              <%!-- Administrators by e-mail, before their first sign-in too (F-1309) --%>
              <form
                id="grant-admin-form"
                phx-submit="grant_admin_emails"
                class="flex flex-col sm:flex-row gap-2 sm:items-end"
              >
                <label class="flex-1 text-xs space-y-1">
                  <span class="block font-medium text-zinc-700 dark:text-zinc-300">
                    {gettext(
                      "Add administrators (can elevate) by email (separate multiple with commas; people who have never signed in can be added too)"
                    )}
                  </span>
                  <.email_input
                    id="grant-admin-emails"
                    name="emails"
                    ac={@ac}
                    placeholder={
                      if @setting.allowed_domain,
                        do: "name@#{@setting.allowed_domain}, name2@#{@setting.allowed_domain}",
                        else: "name@company.com"
                    }
                  />
                </label>
                <button
                  type="submit"
                  id="grant-admin-btn"
                  class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                >
                  {gettext("Allow elevation")}
                </button>
              </form>

              <%= if Accounts.configured_admin_emails() != [] do %>
                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800 text-xs text-zinc-600 dark:text-zinc-400">
                  <span class="font-medium text-zinc-700 dark:text-zinc-300">
                    {gettext("Addresses fixed as able to elevate by environment variable:")}
                  </span>
                  <span class="font-mono text-[11px] ml-1">
                    {Enum.join(Accounts.configured_admin_emails(), ", ")}
                  </span>
                  <p class="text-[11px] text-zinc-400 mt-1">
                    {gettext(
                      "These get the elevation flag back on every sign-in. Removing it here is undone."
                    )}
                  </p>
                </div>
              <% end %>

              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                  <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-3 px-2">{gettext("User account")}</th>
                      <th class="py-3 px-2">{gettext("Elevation to platform admin")}</th>
                      <th class="py-3 px-2">{gettext("Desks administered (app admin)")}</th>
                      <th class="py-3 px-2">{gettext("Status")}</th>
                      <th class="py-3 px-2">{gettext("Last sign-in / last elevation")}</th>
                      <th class="py-3 px-2 text-right">{gettext("Actions")}</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                    <%= for user <- @users do %>
                      <% user_slugs = Enum.map(user.app_admins || [], & &1.app_slug) %>
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
                              {gettext("(you)")}
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
                            {if user.admin_eligible,
                              do: gettext("Platform elevation allowed"),
                              else: gettext("Not allowed")}
                          </span>
                        </td>
                        <td class="py-3 px-2">
                          <%= if user.admin_eligible do %>
                            <span class="text-[11px] text-zinc-400">{gettext(
                              "(can administer all desks)"
                            )}</span>
                          <% else %>
                            <div class="flex flex-wrap items-center gap-1.5">
                              <%= for app <- @apps do %>
                                <% is_app_admin = app.slug in user_slugs %>
                                <button
                                  type="button"
                                  id={"user-#{user.id}-app-#{app.slug}"}
                                  phx-click="toggle_user_app_admin"
                                  phx-value-user_id={user.id}
                                  phx-value-app_slug={app.slug}
                                  title={
                                    if(is_app_admin,
                                      do:
                                        gettext("Click to revoke admin rights for %{app}",
                                          app: app.name
                                        ),
                                      else:
                                        gettext("Click to grant admin rights for %{app}",
                                          app: app.name
                                        )
                                    )
                                  }
                                  class={[
                                    "px-2 py-0.5 rounded text-[10px] font-medium border transition",
                                    if(is_app_admin,
                                      do:
                                        "bg-indigo-50 border-indigo-200 text-indigo-700 dark:bg-indigo-950/40 dark:border-indigo-800 dark:text-indigo-300",
                                      else:
                                        "bg-zinc-50 border-zinc-200 text-zinc-400 hover:text-zinc-700 dark:bg-zinc-900 dark:border-zinc-800 dark:text-zinc-500"
                                    )
                                  ]}
                                >
                                  {if is_app_admin, do: "✓ ", else: "+ "}{app.name}
                                </button>
                              <% end %>
                            </div>
                          <% end %>
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
                            {if user.status == "active",
                              do: gettext("Active"),
                              else: gettext("Disabled")}
                          </span>
                        </td>
                        <td class="py-3 px-2 text-zinc-400">
                          <div>
                            {if user.last_login_at,
                              do: AskDrive.Clock.format(user.last_login_at, "%Y-%m-%d %H:%M"),
                              else: "—"}
                          </div>
                          <div class="text-[10px]">
                            {gettext("Elevated:")} {if user.last_elevated_at,
                              do: AskDrive.Clock.format(user.last_elevated_at, "%Y-%m-%d %H:%M"),
                              else: "—"}
                          </div>
                        </td>
                        <td class="py-3 px-2">
                          <%!-- Self-modification and last-admin removal are rejected server
                                side too; hiding the buttons just avoids a pointless error. --%>
                          <%!-- Handing over (F-921): an administrator may give up their own
                                rights once another one exists --%>
                          <div
                            :if={
                              user.id == @current_user.id and user.admin_eligible and
                                Accounts.count_eligible_admins() > 1 and
                                not Accounts.admin_fixed_by_env?(user)
                            }
                            class="flex justify-end"
                          >
                            <button
                              id={"give-up-admin-#{user.id}"}
                              phx-click="set_admin_eligible"
                              phx-value-id={user.id}
                              phx-value-eligible="false"
                              data-confirm={
                                gettext(
                                  "Remove your own platform administrator rights and go back to being a regular user? You will no longer be able to enter platform administration (to undo this, ask another platform administrator)."
                                )
                              }
                              class="px-2.5 py-1 rounded-lg border border-red-300 text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950/40 text-[11px] font-medium transition"
                            >
                              {gettext("Remove my platform admin rights")}
                            </button>
                          </div>
                          <p
                            :if={user.admin_eligible and Accounts.admin_fixed_by_env?(user)}
                            class="text-[11px] text-zinc-500 text-right"
                          >
                            {gettext(
                              "Fixed by ASK_DRIVE_ADMIN_EMAILS in .env.prod (cannot be removed here)"
                            )}
                          </p>
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
                                  do:
                                    gettext("Remove admin elevation rights from %{email}?",
                                      email: user.email
                                    ),
                                  else:
                                    gettext(
                                      "Make %{email} a platform administrator? After verifying their identity, they will be able to change platform settings.",
                                      email: user.email
                                    )
                                )
                              }
                              class="px-2.5 py-1 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-[11px] font-medium transition"
                            >
                              {if user.admin_eligible,
                                do: gettext("Disallow elevation"),
                                else: gettext("Permit elevation")}
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
                                  do:
                                    gettext(
                                      "Disable %{email}? They will no longer be able to sign in.",
                                      email: user.email
                                    ),
                                  else: gettext("Re-enable %{email}?", email: user.email)
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
                              {if user.status == "active",
                                do: gettext("Disable"),
                                else: gettext("Enable")}
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
                {gettext("Admin elevation history")}
              </h2>
              <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                {gettext(
                  "A record of which account elevated to admin rights and when (latest 100). Failures, revocations and expiries are recorded too. This record cannot be deleted or edited."
                )}
              </p>
            </div>

            <%= if @elevation_logs == [] do %>
              <p class="text-xs text-zinc-500 py-8 text-center">
                {gettext("No elevations recorded yet.")}
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                  <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-3 px-2">{gettext("Date and time")}</th>
                      <th class="py-3 px-2">{gettext("Account")}</th>
                      <th class="py-3 px-2">{gettext("Event")}</th>
                      <th class="py-3 px-2">{gettext("Source IP")}</th>
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

        <%!-- Tab: API Usage Metrics & Logs --%>
        <%= if @current_tab == "metrics" do %>
          <div class="space-y-6">
            <%!-- KPI Cards --%>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">
                  {gettext("Total requests (last 30 days)")}
                </p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {@metrics_summary.total_requests}
                  <span class="text-xs font-normal text-zinc-500">{gettext("times")}</span>
                </p>
                <p class="text-[11px] text-zinc-400 mt-1">
                  {gettext("Success rate: %{rate}%", rate: @metrics_summary.success_rate)}
                </p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">{gettext("Total tokens used")}</p>
                <p class="text-2xl font-bold text-indigo-600 dark:text-indigo-400 mt-1">
                  {@metrics_summary.total_tokens}
                </p>
                <p class="text-[11px] text-zinc-400 mt-1">
                  {gettext("Input %{prompt} / output %{completion}",
                    prompt: @metrics_summary.prompt_tokens,
                    completion: @metrics_summary.completion_tokens
                  )}
                </p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">{gettext("Data sent")}</p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {div(@metrics_summary.total_bytes, 1024)}
                  <span class="text-xs font-normal text-zinc-500">KB</span>
                </p>
                <p class="text-[11px] text-zinc-400 mt-1">({@metrics_summary.total_bytes} bytes)</p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">
                  {gettext("Average response time (latency)")}
                </p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {@metrics_summary.avg_latency_ms}
                  <span class="text-xs font-normal text-zinc-500">ms</span>
                </p>
                <p class="text-[11px] text-zinc-400 mt-1">
                  {gettext("Errors: %{count}", count: @metrics_summary.error_requests)}
                  <span
                    :if={Map.get(@metrics_summary, :rate_limit_errors, 0) > 0}
                    class="text-amber-600 dark:text-amber-400 ml-1 font-medium"
                  >
                    {gettext("(429 rate limit: %{count})", count: @metrics_summary.rate_limit_errors)}
                  </span>
                </p>
              </div>
            </div>

            <%!-- Provider & Model Breakdown --%>
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
                <h3 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "Usage by provider and model"
                  )}
                </h3>
                <%= if @metrics_summary.provider_breakdown == [] do %>
                  <p class="text-xs text-zinc-500 py-4 text-center">
                    {gettext("No API calls recorded yet.")}
                  </p>
                <% else %>
                  <div class="overflow-x-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                        <tr>
                          <th class="py-2.5 px-2">{gettext("Provider")}</th>
                          <th class="py-2.5 px-2">{gettext("Model")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Requests")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Total tokens")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Errors")}</th>
                        </tr>
                      </thead>
                      <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                        <%= for row <- @metrics_summary.provider_breakdown do %>
                          <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition">
                            <td class="py-2.5 px-2 font-medium text-zinc-900 dark:text-zinc-100">
                              {row.provider}
                            </td>
                            <td class="py-2.5 px-2 font-mono text-[11px]">{row.model}</td>
                            <td class="py-2.5 px-2 text-right">{row.requests}</td>
                            <td class="py-2.5 px-2 text-right font-mono text-indigo-600 dark:text-indigo-400">
                              {row.total_tokens}
                            </td>
                            <td class="py-2.5 px-2 text-right">
                              <%= if row.errors > 0 do %>
                                <span class="text-red-600 dark:text-red-400 font-medium">{row.errors}</span>
                              <% else %>
                                <span class="text-zinc-400">0</span>
                              <% end %>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </div>

              <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
                <h3 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-tag" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "Usage by feature and purpose"
                  )}
                </h3>
                <%= if @metrics_summary.purpose_breakdown == [] do %>
                  <p class="text-xs text-zinc-500 py-4 text-center">
                    {gettext("No API calls recorded yet.")}
                  </p>
                <% else %>
                  <div class="overflow-x-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                        <tr>
                          <th class="py-2.5 px-2">{gettext("Purpose")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Number of requests")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Total token count")}</th>
                        </tr>
                      </thead>
                      <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                        <%= for row <- @metrics_summary.purpose_breakdown do %>
                          <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition">
                            <td class="py-2.5 px-2 font-medium text-zinc-900 dark:text-zinc-100">
                              {case row.purpose do
                                "batch_generation" -> gettext("Nightly batch QA generation")
                                "chat_summary" -> gettext("Chat AI summary")
                                "embedding" -> gettext("Embedding vector generation")
                                "generation" -> gettext("Text generation")
                                other -> other
                              end}
                            </td>
                            <td class="py-2.5 px-2 text-right">{row.requests}</td>
                            <td class="py-2.5 px-2 text-right font-mono text-indigo-600 dark:text-indigo-400">
                              {row.total_tokens}
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Recent API Errors Log --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h3 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                    <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-red-500" />
                    {gettext(
                      "Recent API communication errors (for privacy, question text and document content are neither stored nor shown)"
                    )}
                  </h3>
                  <p class="text-xs text-zinc-500 mt-1">
                    {gettext(
                      "History of recent API communication errors. Use it to check for revoked API keys, rate limits (429), timeouts and so on."
                    )}
                  </p>
                </div>
              </div>

              <%= if @recent_api_errors == [] do %>
                <div class="p-4 rounded-xl bg-emerald-50 dark:bg-emerald-950/30 border border-emerald-200 dark:border-emerald-900 text-xs text-emerald-800 dark:text-emerald-300 flex items-center gap-2">
                  <.icon
                    name="hero-check-circle"
                    class="w-4 h-4 text-emerald-600 dark:text-emerald-400 shrink-0"
                  />
                  <span>{gettext("No recent errors. Everything is running normally.")}</span>
                </div>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                    <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                      <tr>
                        <th class="py-2.5 px-2">{gettext("Date and time")}</th>
                        <th class="py-2.5 px-2">{gettext("Provider")}</th>
                        <th class="py-2.5 px-2">{gettext("Model")}</th>
                        <th class="py-2.5 px-2">{gettext("Purpose")}</th>
                        <th class="py-2.5 px-2">{gettext("Error details")}</th>
                        <th class="py-2.5 px-2 text-right">{gettext("Latency")}</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                      <%= for err <- @recent_api_errors do %>
                        <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition">
                          <td class="py-2.5 px-2 font-mono text-[11px] whitespace-nowrap">
                            {AskDrive.Clock.format(err.inserted_at, "%Y-%m-%d %H:%M:%S")}
                          </td>
                          <td class="py-2.5 px-2 font-medium text-zinc-900 dark:text-zinc-100">
                            {err.provider}
                          </td>
                          <td class="py-2.5 px-2 font-mono text-[11px]">{err.model}</td>
                          <td class="py-2.5 px-2">{err.purpose}</td>
                          <td class="py-2.5 px-2 text-red-600 dark:text-red-400 break-all">
                            {err.error_message}
                          </td>
                          <td class="py-2.5 px-2 text-right font-mono whitespace-nowrap">
                            {err.latency_ms} ms
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
            <%!-- Data & Ingestion Token Efficiency (spec 14.6) --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-5">
              <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2 border-b border-zinc-200/60 dark:border-zinc-800 pb-3">
                <div>
                  <h3 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                    <.icon name="hero-document-chart-bar" class="w-5 h-5 text-indigo-600" />
                    {gettext("Token efficiency and structure analysis of indexed data")}
                  </h3>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    {gettext(
                      "Analyzes how efficiently ingested documents are tokenized (text extraction and structuring). Structured text such as Markdown has high token density and search accuracy, while scanned images and complex PDFs tend to have lower token efficiency."
                    )}
                  </p>
                </div>
                <div class="text-right shrink-0">
                  <span class="text-xs font-semibold text-zinc-600 dark:text-zinc-300">
                    {gettext("Documents: %{count}", count: @data_efficiency.total_indexed_docs)}
                  </span>
                  <span class="text-[11px] text-zinc-400 block">
                    {gettext("Total indexed: %{count} tokens", count: @data_efficiency.total_tokens)}
                  </span>
                </div>
              </div>

              <%!-- Format Comparison Cards / Table --%>
              <div class="space-y-3">
                <h4 class="text-xs font-semibold text-zinc-700 dark:text-zinc-300">
                  {gettext("Token efficiency by file format")}
                </h4>
                <%= if @data_efficiency.format_breakdown == [] do %>
                  <p class="text-xs text-zinc-400 py-3 text-center">
                    {gettext("No indexed documents.")}
                  </p>
                <% else %>
                  <div class="overflow-x-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                        <tr>
                          <th class="py-2.5 px-2">{gettext("Format / type")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Document count")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Total token count")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Original data total")}</th>
                          <th class="py-2.5 px-2 text-right">
                            {gettext("Token density (tokens/KB)")}
                          </th>
                          <th class="py-2.5 px-2 text-right">{gettext("Usable text ratio")}</th>
                          <th class="py-2.5 px-2">{gettext("Efficiency rating")}</th>
                        </tr>
                      </thead>
                      <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                        <%= for fmt <- @data_efficiency.format_breakdown do %>
                          <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition">
                            <td class="py-2.5 px-2 font-medium text-zinc-900 dark:text-zinc-100">
                              {fmt.category}
                            </td>
                            <td class="py-2.5 px-2 text-right">{fmt.docs_count}</td>
                            <td class="py-2.5 px-2 text-right font-mono text-indigo-600 dark:text-indigo-400">
                              {fmt.total_tokens}
                            </td>
                            <td class="py-2.5 px-2 text-right font-mono text-[11px]">
                              {div(fmt.total_bytes, 1024)} KB
                            </td>
                            <td class="py-2.5 px-2 text-right font-mono">{fmt.avg_density}</td>
                            <td class="py-2.5 px-2 text-right font-mono">{fmt.avg_ratio}%</td>
                            <td class="py-2.5 px-2">
                              <span class={[
                                "px-2 py-0.5 rounded-full text-[10px] font-medium",
                                cond do
                                  String.starts_with?(fmt.category, "Markdown") or
                                      String.starts_with?(fmt.category, "Plain") ->
                                    "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

                                  String.starts_with?(fmt.category, "CSV") or
                                    String.starts_with?(fmt.category, "Docs") or
                                      String.starts_with?(fmt.category, "Sheets") ->
                                    "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300"

                                  String.starts_with?(fmt.category, "PDF") ->
                                    "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

                                  true ->
                                    "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"
                                end
                              ]}>
                                {cond do
                                  String.starts_with?(fmt.category, "Markdown") or
                                      String.starts_with?(fmt.category, "Plain") ->
                                    gettext("Best (S)")

                                  String.starts_with?(fmt.category, "CSV") or
                                    String.starts_with?(fmt.category, "Docs") or
                                      String.starts_with?(fmt.category, "Sheets") ->
                                    gettext("Good (A)")

                                  String.starts_with?(fmt.category, "PDF") ->
                                    gettext("Standard (B)")

                                  true ->
                                    gettext("Needs review (C)")
                                end}
                              </span>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </div>

              <%!-- Document Details & Advice List --%>
              <div class="space-y-3 pt-3 border-t border-zinc-200/60 dark:border-zinc-800">
                <h4 class="text-xs font-semibold text-zinc-700 dark:text-zinc-300">
                  {gettext("Token efficiency and improvement advice per document")}
                </h4>
                <%= if @data_efficiency.doc_stats == [] do %>
                  <p class="text-xs text-zinc-400 py-3 text-center">
                    {gettext("No indexed documents.")}
                  </p>
                <% else %>
                  <div class="overflow-x-auto max-h-80 overflow-y-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800 sticky top-0 bg-white dark:bg-zinc-900">
                        <tr>
                          <th class="py-2.5 px-2">{gettext("Document")}</th>
                          <th class="py-2.5 px-2">{gettext("Type")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Estimated tokens")}</th>
                          <th class="py-2.5 px-2 text-right">{gettext("Original size")}</th>
                          <th class="py-2.5 px-2">{gettext("Efficiency score")}</th>
                          <th class="py-2.5 px-2">{gettext("Advice for content authors")}</th>
                        </tr>
                      </thead>
                      <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                        <%= for stat <- @data_efficiency.doc_stats do %>
                          <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition">
                            <td
                              class="py-2.5 px-2 font-medium text-zinc-900 dark:text-zinc-100 max-w-xs truncate"
                              title={stat.document.name}
                            >
                              {stat.document.name}
                            </td>
                            <td class="py-2.5 px-2 text-[11px] text-zinc-500">{stat.category}</td>
                            <td class="py-2.5 px-2 text-right font-mono text-indigo-600 dark:text-indigo-400">
                              {stat.total_tokens}
                            </td>
                            <td class="py-2.5 px-2 text-right font-mono text-[11px]">
                              {div(stat.raw_size_bytes, 1024)} KB
                            </td>
                            <td class="py-2.5 px-2 whitespace-nowrap">
                              <span class={[
                                "px-2 py-0.5 rounded-full text-[10px] font-medium",
                                cond do
                                  stat.score_level == :excellent ->
                                    "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

                                  stat.score_level == :good ->
                                    "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300"

                                  stat.score_level == :fair ->
                                    "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

                                  stat.score_level == :poor ->
                                    "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

                                  true ->
                                    "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"
                                end
                              ]}>
                                {stat.score_rating}
                              </span>
                            </td>
                            <td class="py-2.5 px-2 text-[11px] text-zinc-500 leading-snug">
                              {stat.advice}
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Tab 6: Settings Management --%>
        <%= if @current_tab == "update" and @scope == :platform do %>
          <AskDriveWeb.UpdatePanel.update_tab
            status={@update_status}
            setting={@setting}
            form={@form}
            latest={@update_latest}
            checking={@update_checking}
            notify_test={@notify_test}
          />
        <% end %>

        <%= if @current_tab == "settings" do %>
          <div class="space-y-6">
            <%!-- Organization (Google Workspace), platform-wide: spec 6.12 --%>
            <div
              :if={@scope == :platform}
              id="org-settings"
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-building-office-2" class="w-5 h-5 text-indigo-600" />
                  {gettext("Organization and accounts (Google Workspace / domain restriction)")}
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  {gettext("For a company or organization, enter a domain (e.g.")} <code class="font-mono">company.com</code>{gettext(
                    ") to allow access only from that domain. For personal use ("
                  )}<code class="font-mono">@gmail.com</code>
                  {gettext("etc.) or no domain restriction, leave it ")}<strong>{gettext("blank")}</strong>{gettext(
                    " and save (any Google account can then sign in and connect Drive)."
                  )}
                </p>
              </div>
              <.form for={@form} id="org-form" phx-submit="save_settings" class="space-y-4">
                <.input
                  field={@form[:allowed_domain]}
                  type="text"
                  label={gettext("Allowed domain (e.g. company.com; leave blank for no restriction)")}
                  placeholder={gettext("company.com (blank for no restriction)")}
                />
                <div class="flex justify-end">
                  <button
                    type="submit"
                    id="save-org-btn"
                    class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                  >
                    {gettext("Save")}
                  </button>
                </div>
              </.form>

              <%!-- Sign-in methods (spec 6.13 / F-1310): each on or off on its own --%>
              <h3 class="pt-2 text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                {gettext("Sign-in methods")}
              </h3>

              <div
                id="oauth-settings"
                class="p-5 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-6"
              >
                <.form for={@form} id="oauth-form" phx-submit="save_settings" class="space-y-6">
                  <%!-- Section 1: Drive sync OAuth credentials --%>
                  <div class="space-y-3">
                    <div class="flex items-center justify-between">
                      <h3 class="font-semibold text-sm text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                        <.icon name="hero-cloud-arrow-up" class="w-4 h-4 text-indigo-600" />
                        {gettext("OAuth client for Google Drive sync (shared by all desks)")}
                      </h3>
                      <span class={[
                        "text-[11px] font-medium px-2.5 py-0.5 rounded-full",
                        if(AskDrive.Drive.OAuth.client_configured?(),
                          do:
                            "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300 border border-emerald-200/60",
                          else:
                            "bg-amber-50 text-amber-700 dark:bg-amber-950/40 dark:text-amber-300 border border-amber-200/60"
                        )
                      ]}>
                        {if AskDrive.Drive.OAuth.client_configured?(),
                          do: gettext("OAuth client: Set"),
                          else: gettext("OAuth client: Not set")}
                      </span>
                    </div>

                    <p class="text-xs text-zinc-500 leading-relaxed">
                      {gettext(
                        "The Google Cloud OAuth credentials needed to sync Google Drive on every desk. Once registered here, you don't need to set a client ID on each desk. (Required for Drive sync even if you don't use Google sign-in.)"
                      )}
                    </p>

                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 pt-1">
                      <.input
                        field={@form[:google_client_id]}
                        type="text"
                        label={gettext("OAuth client ID")}
                        placeholder={gettext("e.g. xxxxxxxx.apps.googleusercontent.com")}
                      />
                      <.input
                        field={@form[:google_client_secret]}
                        type="password"
                        value=""
                        label={
                          gettext("OAuth client secret (%{state})",
                            state: secret_state(@setting.google_client_secret)
                          )
                        }
                        placeholder={gettext("e.g. GOCSPX-xxxxxxxxxxxx")}
                      />
                    </div>

                    <div class="flex flex-wrap items-center justify-between gap-3 pt-1">
                      <div class="flex items-center gap-2">
                        <button
                          type="button"
                          id="test-oauth-client-btn"
                          phx-click="test_oauth_client"
                          phx-value-scope="platform"
                          class="px-3 py-2 rounded-xl border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium transition"
                        >
                          {gettext("Test connection")}
                        </button>
                        <.client_test_result result={@oauth_client_test[:platform]} />
                      </div>
                      <button
                        type="submit"
                        id="save-oauth-btn"
                        class="px-5 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                      >
                        {gettext("Save")}
                      </button>
                    </div>
                  </div>

                  <%!-- Section 2: Google Login (SSO) toggle --%>
                  <div class="pt-5 border-t border-zinc-100 dark:border-zinc-800 space-y-3">
                    <div class="flex items-center justify-between">
                      <h3 class="font-semibold text-sm text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                        <.icon name="hero-arrow-left-on-rectangle" class="w-4 h-4 text-indigo-600" />
                        {gettext("Sign-in with a Google account (SSO)")}
                      </h3>
                      <span class={[
                        "text-[11px] font-medium px-2.5 py-0.5 rounded-full",
                        if(oauth_status(@setting) == :login,
                          do:
                            "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
                          else: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800"
                        )
                      ]}>
                        {case oauth_status(@setting) do
                          :unset -> gettext("Not set")
                          :login -> gettext("Sign-in: On")
                          :drive_only -> gettext("Sign-in: Off (Drive sync only)")
                        end}
                      </span>
                    </div>

                    <p class="text-xs text-zinc-500 leading-relaxed">
                      {gettext(
                        "Lets users sign in with their Google account on the sign-in screen (uses the OAuth client above). "
                      )}<strong>{gettext(
                        "Drive sync above keeps working even with Google sign-in turned off."
                      )}</strong>
                    </p>

                    <AskDriveWeb.FeatureToggle.toggle
                      id="toggle-oauth-login"
                      feature="oauth_login"
                      on={@setting.oauth_login_enabled != false}
                      label={gettext("Google sign-in")}
                      hint={
                        gettext(
                          "Show \"Sign in with Google\" on the sign-in screen (can be turned on after saving the OAuth client above)"
                        )
                      }
                    />

                    <.redirect_uri_help />
                  </div>
                </.form>
              </div>

              <%!-- Sign-in with Google Secure LDAP, platform-wide (spec 6.13) --%>
              <div
                id="ldap-settings"
                class="p-4 rounded-xl border border-zinc-200/80 dark:border-zinc-800 space-y-4"
              >
                <div>
                  <h2 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200 flex items-center gap-2">
                    <.icon name="hero-lock-closed" class="w-4 h-4 text-indigo-500" />
                    {gettext("Sign-in with Google Secure LDAP")}
                    <span class={[
                      "text-[11px] font-medium px-2 py-0.5 rounded-full",
                      if(AskDrive.Ldap.enabled?(@setting),
                        do:
                          "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
                        else: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800"
                      )
                    ]}>
                      {if AskDrive.Ldap.enabled?(@setting), do: gettext("On"), else: gettext("Off")}
                    </span>
                  </h2>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    {gettext(
                      "Shows email and password fields on the sign-in screen and checks the Google Workspace password with Secure LDAP (AskDrive does not store passwords). Works without a public URL. In the Google Admin console, add an LDAP client, allow \"Verify user credentials\" and \"Read user information\", and register the issued certificate (.crt) and private key (.key) here."
                    )}
                  </p>
                  <p class="text-xs text-amber-700 dark:text-amber-300 mt-1 leading-relaxed">
                    {gettext(
                      "Password checks over LDAP skip Google's 2-step verification. 5 failures for the same account within 5 minutes lock it for 15 minutes; 10 failures from the same device (browser) within 24 hours lock it for 24 hours."
                    )}
                  </p>
                </div>

                <% ldap_cert =
                  @setting.ldap_client_cert && AskDrive.SSL.describe_cert(@setting.ldap_client_cert) %>
                <div class="text-xs text-zinc-600 dark:text-zinc-400 space-y-0.5">
                  <%= case ldap_cert do %>
                    <% {:ok, info} -> %>
                      <p id="ldap-cert-info">
                        {gettext("Registered certificate:")} <span class="font-mono">{info["subject"]}</span>{gettext(
                          " · Expires"
                        )} {String.slice(
                          info["not_after"],
                          0,
                          10
                        )}
                      </p>
                    <% _ -> %>
                      <p>{gettext("Client certificate: Not registered")}</p>
                  <% end %>
                  <p>
                    {gettext("Private key: %{key} · CA certificate: %{ca}",
                      key: secret_state(@setting.ldap_client_key),
                      ca:
                        if(@setting.ldap_ca_cert,
                          do: gettext("Registered"),
                          else: gettext("None (verified with a public CA)")
                        )
                    )}
                  </p>
                </div>

                <AskDriveWeb.FeatureToggle.toggle
                  id="toggle-ldap"
                  feature="ldap"
                  on={@setting.ldap_enabled == true}
                  label={gettext("LDAP sign-in")}
                  hint={
                    gettext(
                      "Can be turned on after saving the settings below (including the client certificate and private key). While it is on, saving fails if settings are missing"
                    )
                  }
                  confirm_off={
                    gettext(
                      "This turns off LDAP sign-in. Users who can only sign in with LDAP will be locked out. Continue?"
                    )
                  }
                />
                <form id="ldap-form" phx-submit="save_ldap" phx-change="ldap_change" class="space-y-4">
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
                    <label class="space-y-1 sm:col-span-2">
                      <span class="block font-medium">{gettext("LDAP server")}</span>
                      <input
                        type="text"
                        name="ldap[ldap_host]"
                        value={@ldap_form["ldap_host"]}
                        placeholder={AskDrive.Ldap.default_host()}
                        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                      />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">{gettext("Port (LDAPS)")}</span>
                      <input
                        type="number"
                        name="ldap[ldap_port]"
                        value={@ldap_form["ldap_port"]}
                        placeholder={AskDrive.Ldap.default_port()}
                        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                      />
                    </label>
                    <label class="space-y-1 sm:col-span-3">
                      <span class="block font-medium">{gettext(
                        "Base DN (blank = derived from the domain: %{dn})",
                        dn:
                          AskDrive.Ldap.domain_base_dn(@setting.allowed_domain) ||
                            gettext("domain not set")
                      )}</span>
                      <input
                        type="text"
                        name="ldap[ldap_base_dn]"
                        value={@ldap_form["ldap_base_dn"]}
                        placeholder={
                          AskDrive.Ldap.domain_base_dn(@setting.allowed_domain) || "dc=company,dc=com"
                        }
                        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
                      />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">{gettext("Client certificate (.crt)")}</span>
                      <.live_file_input upload={@uploads.ldap_cert} class={ssl_file_input_class()} />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">{gettext("Private key (.key)")}</span>
                      <.live_file_input upload={@uploads.ldap_key} class={ssl_file_input_class()} />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">{gettext(
                        "CA certificate (optional; not needed for Google)"
                      )}</span>
                      <.live_file_input upload={@uploads.ldap_ca} class={ssl_file_input_class()} />
                    </label>
                  </div>
                  <label
                    :if={@setting.ldap_ca_cert}
                    class="flex items-center gap-2 text-xs text-zinc-600"
                  >
                    <input
                      type="checkbox"
                      name="ldap[clear_ca]"
                      value="true"
                      class="rounded border-zinc-300"
                    /> {gettext("Delete the registered CA certificate")}
                  </label>
                  <details class="text-xs">
                    <summary class="cursor-pointer text-zinc-500">
                      {gettext("Access credentials (optional)")}
                    </summary>
                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mt-2">
                      <label class="space-y-1">
                        <span class="block font-medium">{gettext("Username (bind DN)")}</span>
                        <input
                          type="text"
                          name="ldap[ldap_bind_dn]"
                          value={@ldap_form["ldap_bind_dn"]}
                          class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                        />
                      </label>
                      <label class="space-y-1">
                        <span class="block font-medium">{gettext("Password (%{state})",
                          state: secret_state(@setting.ldap_bind_password)
                        )}</span>
                        <input
                          type="password"
                          name="ldap[ldap_bind_password]"
                          value=""
                          autocomplete="new-password"
                          class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                        />
                      </label>
                    </div>
                    <p class="text-zinc-400 mt-1">
                      {gettext(
                        "Usually not needed, since Google connects with the certificate alone. Enter these only if you generated \"Access credentials\" in the Admin console."
                      )}
                    </p>
                  </details>
                  <p
                    :if={@ldap_pending != %{}}
                    id="ldap-pending"
                    class="text-xs text-amber-700 dark:text-amber-300"
                  >
                    {gettext("Selected, not saved yet: %{files} (registered when you press \"Save\")",
                      files:
                        @ldap_pending
                        |> Enum.map(fn {_kind, {name, _pem}} -> name end)
                        |> Enum.join(gettext(", "))
                    )}
                  </p>
                  <div class="flex flex-wrap justify-end gap-2">
                    <button
                      type="submit"
                      name="op"
                      value="test"
                      id="test-ldap-btn"
                      class="px-4 py-2.5 rounded-xl border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium text-xs transition"
                    >
                      {gettext("Test connection (with the values entered)")}
                    </button>
                    <button
                      type="submit"
                      name="op"
                      value="save"
                      id="save-ldap-btn"
                      class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                    >
                      {gettext("Save")}
                    </button>
                  </div>
                </form>

                <%!-- Active sign-in locks (spec F-1305), liftable by an administrator --%>
                <div
                  id="login-locks"
                  class="pt-3 border-t border-zinc-200/60 dark:border-zinc-800 space-y-2"
                >
                  <h3 class="text-xs font-semibold text-zinc-600 dark:text-zinc-300">
                    {gettext("Locked sign-ins (%{count})", count: length(@login_locks))}
                  </h3>
                  <p :if={@login_locks == []} class="text-xs text-zinc-400">
                    {gettext("No accounts or devices are locked.")}
                  </p>
                  <table
                    :if={@login_locks != []}
                    class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                  >
                    <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                      <tr>
                        <th class="py-1.5 px-2">{gettext("Target")}</th>
                        <th class="py-1.5 px-2">{gettext("Device")}</th>
                        <th class="py-1.5 px-2">{gettext("Unlocks at")}</th>
                        <th class="py-1.5 px-2"></th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                      <tr :for={lock <- @login_locks} id={"login-lock-#{lock.id}"}>
                        <td class="py-1.5 px-2">
                          {cond do
                            lock.scope == "account" and String.starts_with?(lock.key, "access:") ->
                              gettext("Passphrase for desk \"%{desk}\" (5 failures in 5 minutes)",
                                desk:
                                  lock.key
                                  |> String.trim_leading("access:")
                                  |> String.split("|")
                                  |> hd()
                              )

                            lock.scope == "account" ->
                              gettext("Account: %{email} (5 failures in 5 minutes)",
                                email: to_string(lock.email)
                              )

                            true ->
                              gettext("Device (10 failures in 24 hours)")
                          end}
                        </td>
                        <td class="py-1.5 px-2">
                          {AskDrive.Accounts.LoginThrottle.describe_user_agent(lock.user_agent)}・{lock.ip}
                        </td>
                        <td class="py-1.5 px-2 font-mono whitespace-nowrap">
                          {AskDrive.Clock.format(lock.locked_until, "%m/%d %H:%M")}
                        </td>
                        <td class="py-1.5 px-2 text-right">
                          <button
                            id={"unlock-#{lock.id}"}
                            phx-click="unlock_login"
                            phx-value-id={lock.id}
                            data-confirm={gettext("Lift this lock?")}
                            class="px-2.5 py-1 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 font-medium"
                          >
                            {gettext("Unlock")}
                          </button>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <p
                  :if={@ldap_test}
                  id="ldap-test-result"
                  class={[
                    "text-xs px-3 py-2 rounded-lg border",
                    if(@ldap_test == :ok,
                      do:
                        "bg-emerald-50 border-emerald-200 text-emerald-800 dark:bg-emerald-950/40 dark:border-emerald-900 dark:text-emerald-200",
                      else:
                        "bg-red-50 border-red-200 text-red-800 dark:bg-red-950/40 dark:border-red-900 dark:text-red-200"
                    )
                  ]}
                >
                  {case @ldap_test do
                    :ok ->
                      gettext(
                        "Connected (certificate and base DN are OK). Try a password on the sign-in screen."
                      )

                    {:error, message} ->
                      gettext("Cannot connect: %{message}", message: message)
                  end}
                </p>
              </div>
            </div>

            <%!-- Required login, platform-wide (spec F-1308) --%>
            <% {auth_state, auth_source} = AskDriveWeb.UserAuth.auth_mode() %>
            <div
              :if={@scope == :platform}
              id="auth-settings"
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-user-circle" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "Required sign-in"
                  )}
                  <span class={[
                    "text-[11px] font-medium px-2 py-0.5 rounded-full",
                    if(auth_state == :enabled,
                      do:
                        "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
                      else: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"
                    )
                  ]}>
                    {if auth_state == :enabled, do: gettext("On"), else: gettext("Off (guest / POC)")}
                  </span>
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  {gettext(
                    "When on, every screen including the desk list and chat requires sign-in, and the admin screen also requires identity confirmation (your password with Secure LDAP, otherwise a sign-in within the last 10 minutes). While off, anyone can use the chat and the admin screen without signing in. If you get locked out, run"
                  )}
                  <code class="font-mono">./app.sh auth disable</code>
                  {gettext("on the server to turn it off again.")}
                </p>
              </div>

              <p
                :if={auth_source == :env}
                id="auth-env-fixed"
                class="text-xs px-3 py-2 rounded-lg bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300"
              >
                {gettext("Fixed by the environment variable")} <code class="font-mono">ASK_DRIVE_DISABLE_AUTH</code>{gettext(
                  " (.env.prod). To switch it from this screen or with ./app.sh auth, remove that line from .env.prod and restart."
                )}
              </p>

              <form
                :if={auth_source != :env && auth_state == :disabled}
                id="enable-auth-form"
                phx-submit="enable_auth"
                class="space-y-3"
              >
                <label class="block text-xs space-y-1">
                  <span class="block font-medium text-zinc-700 dark:text-zinc-300">
                    {gettext(
                      "Administrator email addresses (comma-separated for several; after turning it on, sign in with one of them and elevate)"
                    )}
                  </span>
                  <div class="sm:w-96">
                    <.email_input
                      id="enable-auth-admin-email"
                      name="admin_email"
                      ac={@ac}
                      placeholder={
                        if @setting.allowed_domain,
                          do: "name@#{@setting.allowed_domain}, name2@#{@setting.allowed_domain}",
                          else: "name@company.com, name2@company.com"
                      }
                    />
                  </div>
                </label>
                <p class="text-xs text-zinc-500">
                  {gettext(
                    "Requirement: a sign-in method (Google Secure LDAP or Google sign-in) is set up. Turning it on also takes this browser to the sign-in screen."
                  )}
                </p>
                <button
                  type="submit"
                  id="enable-auth-btn"
                  data-confirm={
                    gettext(
                      "Turn on required sign-in? Afterwards you cannot enter the admin screen without signing in and confirming your identity."
                    )
                  }
                  class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                >
                  {gettext("Turn on required sign-in")}
                </button>
              </form>

              <div :if={auth_source != :env && auth_state == :enabled} class="flex justify-end">
                <button
                  id="disable-auth-btn"
                  phx-click="disable_auth"
                  data-confirm={
                    gettext(
                      "Turn off required sign-in? Anyone will be able to use the chat and the admin screen without signing in."
                    )
                  }
                  class="px-4 py-2.5 rounded-xl border border-red-300 text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950/40 font-medium text-xs transition"
                >
                  {gettext("Turn off required sign-in (back to guest / POC)")}
                </button>
              </div>
            </div>

            <%!-- Card 1: How platform administrators get in (no shared password) --%>
            <div
              :if={@scope == :platform}
              id="platform-admin-entry-card"
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-shield-check" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "How platform administrators get in"
                  )}
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  {gettext(
                    "Platform administrators (accounts marked \"can elevate\" in user management) get in from \"Platform admin\" in the header by confirming their identity with their own account. There is no shared password."
                  )}
                  {if AdminAccess.confirmation_method() == :ldap_password,
                    do:
                      gettext(
                        "Google Secure LDAP is on, so you confirm with your own Google Workspace password (typos count toward the same lock as LDAP sign-in)."
                      ),
                    else:
                      gettext(
                        "Google Secure LDAP is off, so you get straight in if you signed in within the last %{minutes} minutes (otherwise you sign in again).",
                        minutes: AskDrive.Accounts.AppAdminAccess.fresh_login_minutes()
                      )}
                </p>
              </div>

              <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 pt-2 border-t border-zinc-200/60 dark:border-zinc-800">
                <.input
                  field={@form[:admin_session_minutes]}
                  type="number"
                  label={gettext("Admin elevation duration (minutes)")}
                  min="1"
                  max="480"
                  form="settings-form"
                />
              </div>
              <p class="text-[11px] text-zinc-400">
                {gettext(
                  "The elevation duration takes effect with \"Save settings\" below (the same duration applies to desk admin screens)."
                )}
              </p>
            </div>

            <%!-- The app's administrators (spec F-1114) --%>
            <div
              :if={@scope == :app}
              id="app-admins-card"
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-user-group" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "Desk administrators"
                  )}
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  {gettext(
                    "Only the administrators listed here can enter this desk's admin screen (including Drive settings and API keys); platform administrators cannot. Each administrator gets in by confirming their identity with their own account. You can add administrators, and remove yourself to hand over (the last one cannot be removed)."
                  )}
                </p>
              </div>

              <ul class="divide-y divide-zinc-200/60 dark:divide-zinc-800 text-xs">
                <li
                  :for={admin <- @app_admins[@app.slug] || []}
                  id={"app-admin-#{admin.id}"}
                  class="flex items-center justify-between py-2"
                >
                  <span class="text-zinc-800 dark:text-zinc-200">
                    {admin.email}
                    <span :if={admin.id == @current_user.id} class="text-zinc-400">{gettext(
                      "(this is you)"
                    )}</span>
                    <span :if={is_nil(admin.last_login_at)} class="text-zinc-400">{gettext(
                      "(never signed in)"
                    )}</span>
                  </span>
                  <button
                    :if={length(@app_admins[@app.slug] || []) > 1}
                    id={"remove-app-admin-#{admin.id}"}
                    phx-click="remove_app_admin"
                    phx-value-app_slug={@app.slug}
                    phx-value-user_id={admin.id}
                    data-confirm={
                      if(admin.id == @current_user.id,
                        do:
                          gettext(
                            "Remove yourself from this desk's administrators? You will no longer be able to enter this desk's admin screen."
                          ),
                        else:
                          gettext("Remove %{email} from this desk's administrators?",
                            email: admin.email
                          )
                      )
                    }
                    class="px-2.5 py-1 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-[11px] font-medium"
                  >
                    {if admin.id == @current_user.id,
                      do: gettext("Remove myself"),
                      else: gettext("Remove")}
                  </button>
                </li>
              </ul>

              <form
                id="add-app-admins-form"
                phx-submit="add_app_admins"
                class="flex flex-col sm:flex-row gap-2 sm:items-end"
              >
                <input type="hidden" name="app_slug" value={@app.slug} />
                <label class="flex-1 text-xs space-y-1">
                  <span class="block font-medium text-zinc-700 dark:text-zinc-300">
                    {gettext(
                      "Add administrators (email addresses, comma-separated for several; people who have never signed in can be added too)"
                    )}
                  </span>
                  <.email_input id="add-app-admins-emails" name="emails" ac={@ac} />
                </label>
                <button
                  type="submit"
                  id="add-app-admins-btn"
                  class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                >
                  {gettext("Add")}
                </button>
              </form>

              <div
                :if={@app_admin_changes != []}
                id="app-admin-changes"
                class="text-[11px] text-zinc-500 space-y-0.5"
              >
                <p class="font-medium text-zinc-600 dark:text-zinc-400">
                  {gettext("Administrator change history")}
                </p>
                <p
                  :for={c <- @app_admin_changes}
                  class={c.by_platform? && "text-amber-700 dark:text-amber-300"}
                >
                  {AskDrive.Clock.format(c.at, "%m/%d %H:%M") <>
                    " " <>
                    if(c.event == "app_admin_added",
                      do:
                        gettext("%{actor}%{by} added %{target}",
                          actor: c.actor,
                          by: if(c.by_platform?, do: gettext(" (platform admin)"), else: ""),
                          target: c.target || ""
                        ),
                      else:
                        gettext("%{actor}%{by} removed %{target}",
                          actor: c.actor,
                          by: if(c.by_platform?, do: gettext(" (platform admin)"), else: ""),
                          target: c.target || ""
                        )
                    )}
                </p>
              </div>
            </div>

            <%!-- Card 1c: App Access Password (合言葉 / 利用制限) --%>
            <div
              :if={@scope == :app}
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                    <.icon name="hero-lock-closed" class="w-5 h-5 text-indigo-600" /> {gettext(
                      "Desk access password"
                    )}
                  </h2>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    {gettext(
                      "A password that limits who can use this desk's chat. When on, only users who enter the correct password can use the chat."
                    )}
                  </p>
                </div>
              </div>

              <AskDriveWeb.FeatureToggle.toggle
                id="toggle-access-password"
                feature="access_password"
                on={@setting.access_password_enabled == true}
                label={gettext("Restrict access with a password")}
                hint={
                  if @setting.access_password_hash,
                    do:
                      gettext("When on, only people who enter the password can use this desk's chat"),
                    else: gettext("Save a password below first")
                }
                confirm_on={
                  gettext(
                    "This turns on password restriction. Users who don't know the password will no longer be able to use this desk. Continue?"
                  )
                }
              />

              <.form
                for={@access_password_form}
                id="access-password-form"
                phx-submit="save_access_password"
                class="grid grid-cols-1 sm:grid-cols-3 gap-4 items-end"
              >
                <.input
                  field={@access_password_form[:password]}
                  type="password"
                  value=""
                  label={
                    if @setting.access_password_hash,
                      do:
                        gettext("New password (at least %{count} characters)",
                          count: AdminAccess.min_password_length()
                        ),
                      else:
                        gettext("Desk access password (at least %{count} characters)",
                          count: AdminAccess.min_password_length()
                        )
                  }
                  autocomplete="new-password"
                  required
                />
                <div class="flex items-end gap-3 sm:col-span-2">
                  <div class="flex-1">
                    <.input
                      field={@access_password_form[:confirmation]}
                      type="password"
                      value=""
                      label={gettext("Confirm password")}
                      autocomplete="new-password"
                      required
                    />
                  </div>
                  <button
                    type="submit"
                    id="save-access-password-btn"
                    class="px-4 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition whitespace-nowrap"
                  >
                    {if @setting.access_password_hash,
                      do: gettext("Change password"),
                      else: gettext("Save password")}
                  </button>
                </div>
              </.form>
            </div>

            <%!-- Card 2: Google Drive sync — how to authenticate, which folder, and a test --%>
            <div
              :if={@scope == :app}
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div class="flex items-center justify-between">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cloud-arrow-down" class="w-5 h-5 text-indigo-600" />
                  {gettext("Google Drive sync settings")}
                </h2>
                <%= if Accounts.drive_connected?() do %>
                  <span class="text-xs px-2.5 py-1 rounded-full font-medium bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300 border border-emerald-200/50">
                    {gettext("Connected: %{identity}", identity: to_string(Accounts.drive_identity()))}
                  </span>
                <% else %>
                  <span class="text-xs px-2.5 py-1 rounded-full font-medium bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50">
                    {gettext("Not connected")}
                  </span>
                <% end %>
              </div>

              <div class="flex gap-2 p-1 rounded-xl bg-zinc-100 dark:bg-zinc-800 w-fit text-xs font-medium">
                <%!-- OAuth: a real Google account authorizes Drive sync, with this desk's own OAuth
                      client or the platform's (F-346) --%>
                <button
                  type="button"
                  id="drive-auth-mode-oauth"
                  phx-click="set_drive_auth_mode"
                  phx-value-mode="oauth"
                  class={[
                    "px-3 py-1.5 rounded-lg transition",
                    if(@drive_mode == "oauth",
                      do: "bg-white dark:bg-zinc-900 shadow-sm text-zinc-900 dark:text-zinc-100",
                      else: "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
                    )
                  ]}
                >
                  {gettext("Google account authorization")}
                </button>
                <button
                  type="button"
                  id="drive-auth-mode-service-account"
                  phx-click="set_drive_auth_mode"
                  phx-value-mode="service_account"
                  class={[
                    "px-3 py-1.5 rounded-lg transition",
                    if(@drive_mode == "service_account",
                      do: "bg-white dark:bg-zinc-900 shadow-sm text-zinc-900 dark:text-zinc-100",
                      else: "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
                    )
                  ]}
                >
                  {gettext("Service account")}
                </button>
              </div>

              <%!-- One form for the whole card — the authentication of the chosen mode and the
                    folder — saved by the single button at its bottom --%>
              <.form
                for={@form}
                id="drive-settings-form"
                phx-submit="save_drive_settings"
                phx-change="drive_form_change"
                class="space-y-4"
              >
                <%= if @drive_mode == "service_account" do %>
                  <p class="text-xs text-zinc-500 leading-relaxed">
                    {gettext(
                      "No browser authorization is needed, so this avoids Google's redirect_uri restrictions (rejection of raw IP addresses and"
                    )}
                    <code
                      class="font-mono text-[11px]"
                      phx-no-curly-interpolation
                    >.local</code>
                    {gettext("host names). Open")}
                    <a
                      href="https://console.cloud.google.com/iam-admin/serviceaccounts"
                      target="_blank"
                      class="text-indigo-600 dark:text-indigo-400 underline"
                    >
                      Google Cloud Console
                    </a>
                    {gettext(
                      "to create a service account, then download its JSON key and paste it below. After that, share the Drive folder to sync with the service account's email address ("
                    )}<code
                      class="font-mono text-[11px]"
                      phx-no-curly-interpolation
                    >...@...iam.gserviceaccount.com</code>
                    {gettext("). Don't forget this step.")}
                  </p>

                  <div id="service-account-fields" class="space-y-3">
                    <.input
                      field={@form[:drive_service_account_json]}
                      type="textarea"
                      value=""
                      rows="6"
                      label={
                        gettext("Service account JSON key (%{state})",
                          state: secret_state(@setting.drive_service_account_json)
                        )
                      }
                      placeholder={
                        ~s({"type": "service_account", "client_email": "...", "private_key": "...", ...})
                      }
                      class="font-mono text-[11px]"
                    />
                    <p class="text-[11px] text-zinc-500 -mt-1">
                      {gettext(
                        "If already saved, you can leave this blank (the existing key is kept)."
                      )}
                    </p>
                    <.input
                      field={@form[:drive_impersonate_email]}
                      type="email"
                      label={gettext("User to act as (domain-wide delegation, optional)")}
                      placeholder="sync@example.com"
                    />
                    <p class="text-[11px] text-zinc-500 leading-relaxed -mt-1">
                      {gettext(
                        "If the folder to sync is in a shared drive that only users in your organization can access, the service account (treated as outside the organization) cannot be added to it. In that case, enter the email address of an internal user who can view the folder, and in the Google Admin console → \"Security\" → \"API controls\" → \"Domain-wide delegation\", authorize the client ID"
                      )}
                      <code class="font-mono">{service_account_client_id(@setting) ||
                        gettext("(client_id from the JSON key)")}</code>
                      {gettext("for the scope")}
                      <code class="font-mono" phx-no-curly-interpolation>https://www.googleapis.com/auth/drive.readonly</code>
                      {gettext("— or leave it blank to access Drive as the service account itself.")}
                    </p>
                    <div class="flex flex-wrap items-center gap-3">
                      <button
                        type="button"
                        id="test-service-account-btn"
                        phx-click="test_service_account"
                        class="px-3 py-2 rounded-xl border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium transition"
                      >
                        {gettext("Test connection")}
                      </button>
                      <button
                        :if={Accounts.drive_connected?()}
                        type="button"
                        id="disconnect-service-account-btn"
                        phx-click="disconnect_service_account"
                        data-confirm={gettext("Delete the saved service account credentials?")}
                        class="inline-flex items-center gap-1.5 px-3 py-2 rounded-xl bg-red-50 hover:bg-red-100 text-red-700 dark:bg-red-950/40 dark:hover:bg-red-900/60 dark:text-red-300 font-medium text-xs transition"
                      >
                        <.icon name="hero-x-circle" class="w-4 h-4" /> {gettext("Delete")}
                      </button>
                    </div>
                    <%= case @service_account_test do %>
                      <% {:ok, message} -> %>
                        <p class="text-[11px] text-emerald-600 dark:text-emerald-400">{message}</p>
                      <% {:error, message} -> %>
                        <p class="text-[11px] text-red-600 dark:text-red-400">{message}</p>
                      <% _ -> %>
                    <% end %>
                  </div>
                <% else %>
                  <%!-- Google account authentication (F-348): enter the account, press 接続.
                        From a browser on the server itself Google comes straight back to
                        AskDrive; from another PC the address Google ends on is pasted. --%>
                  <div id="drive-google-account" class="space-y-4">
                    <%= if @account do %>
                      <%!-- Connected state banner --%>
                      <div class="p-4 rounded-xl bg-emerald-50/80 dark:bg-emerald-950/40 border border-emerald-200 dark:border-emerald-800/80 flex flex-col sm:flex-row sm:items-center justify-between gap-3 shadow-xs">
                        <div class="flex items-center gap-3">
                          <div class="w-9 h-9 rounded-full bg-emerald-100 dark:bg-emerald-900/60 flex items-center justify-center shrink-0">
                            <.icon
                              name="hero-check-circle"
                              class="w-5 h-5 text-emerald-600 dark:text-emerald-400"
                            />
                          </div>
                          <div>
                            <p class="text-xs font-semibold text-emerald-900 dark:text-emerald-200">
                              {gettext("Google Drive connected")}
                            </p>
                            <p class="text-xs font-mono text-emerald-700 dark:text-emerald-300">
                              {@account.email}
                              <span class="text-[11px] font-sans text-emerald-600 dark:text-emerald-400">{gettext(
                                "(syncs with this account's permissions)"
                              )}</span>
                            </p>
                          </div>
                        </div>
                        <div class="flex items-center gap-2 self-end sm:self-auto">
                          <.link
                            href={
                              ~p"/auth/google/disconnect?#{[return_to: @base_path <> "/admin?tab=settings", app: @app && @app.slug]}"
                            }
                            class="px-3 py-1.5 rounded-lg border border-red-200 hover:border-red-300 bg-white dark:bg-zinc-900 hover:bg-red-50 dark:hover:bg-red-950/40 text-red-700 dark:text-red-300 font-medium text-xs transition shadow-xs"
                          >
                            {gettext("Disconnect")}
                          </.link>
                        </div>
                      </div>
                    <% else %>
                      <%!-- Not connected: 3-Step Setup Guide & Inputs --%>
                      <div class="p-5 rounded-2xl bg-zinc-50/80 dark:bg-zinc-950/50 border border-zinc-200/90 dark:border-zinc-800 space-y-5">
                        <div class="flex items-center justify-between pb-1 border-b border-zinc-200/60 dark:border-zinc-800">
                          <h4 class="text-xs font-bold text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                            <.icon
                              name="hero-arrow-path-rounded-square"
                              class="w-4 h-4 text-indigo-600"
                            /> {gettext("Connect Google Drive (3 steps)")}
                          </h4>
                          <span class="text-[11px] text-amber-700 dark:text-amber-400 font-medium bg-amber-50 dark:bg-amber-950/40 px-2.5 py-0.5 rounded-full border border-amber-200/60 dark:border-amber-900/60">
                            {gettext("Not connected yet")}
                          </span>
                        </div>

                        <%!-- Step 1 --%>
                        <div class="flex items-start gap-3">
                          <span class="w-6 h-6 rounded-full bg-indigo-600 text-white font-bold text-xs flex items-center justify-center shrink-0 mt-0.5 shadow-xs">
                            1
                          </span>
                          <div class="flex-1 space-y-1.5">
                            <label class="block text-xs font-semibold text-zinc-800 dark:text-zinc-200">
                              {gettext("Enter the Google account to sync")}
                            </label>
                            <p class="text-[11px] text-zinc-500">
                              {gettext(
                                "Enter an account (Gmail or Workspace) that can view the Drive folder to sync."
                              )}
                            </p>
                            <input
                              type="email"
                              name="drive_login_hint"
                              id="drive-login-hint"
                              value={@drive_login_hint}
                              placeholder={gettext("e.g. sync-drive@gmail.com or sync@company.com")}
                              class="w-full sm:w-80 px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 text-xs shadow-xs"
                            />
                          </div>
                        </div>

                        <%!-- Step 2 --%>
                        <div class="flex items-start gap-3">
                          <span class="w-6 h-6 rounded-full bg-indigo-600 text-white font-bold text-xs flex items-center justify-center shrink-0 mt-0.5 shadow-xs">
                            2
                          </span>
                          <div class="flex-1 space-y-2">
                            <label class="block text-xs font-semibold text-zinc-800 dark:text-zinc-200">
                              {gettext("Open Google's authorization page and click \"Allow\"")}
                            </label>
                            <p class="text-[11px] text-zinc-500">
                              {gettext(
                                "The button opens the Google sign-in page in a new window. Sign in and \"Allow\" access to Drive."
                              )}
                            </p>
                            <div class="pt-0.5">
                              <%= cond do %>
                                <% not @drive_oauth_ready? -> %>
                                  <button
                                    type="button"
                                    id="drive-connect-btn"
                                    phx-click="drive_connect_needs_client"
                                    class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                                  >
                                    <.icon name="hero-key" class="w-4 h-4" /> {gettext(
                                      "Set up the OAuth client to connect"
                                    )}
                                  </button>
                                <% true -> %>
                                  <a
                                    id="drive-connect-btn"
                                    href={@drive_auth.url}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                                  >
                                    <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
                                    {gettext("Open Google's authorization page (new window)")}
                                  </a>
                              <% end %>
                            </div>

                            <p
                              :if={@drive_oauth_ready?}
                              id="drive-connect-target"
                              class="text-[11px] text-zinc-500 pt-1"
                            >
                              {gettext("Client ID in use:")}
                              <code class="font-mono select-all">{@drive_client_id}</code>
                              {gettext("/ Redirect URI:")}
                              <code class="font-mono select-all">{@drive_redirect_uri}</code>
                            </p>

                            <p
                              :if={@drive_oauth_ready?}
                              id="drive-redirect-mismatch-help"
                              class="text-[11px] text-amber-700 dark:text-amber-300"
                            >
                              {gettext(
                                "Note: If Google shows \"Error 400: redirect_uri_mismatch\", the OAuth client type is \"Web application\". In Google Cloud Console, add"
                              )}
                              <code class="font-mono select-all">{@drive_redirect_uri}</code>
                              {gettext(
                                "to the authorized redirect URIs, or create a client of type \"Desktop app\" (no registration needed for desktop apps)."
                              )}
                            </p>
                          </div>
                        </div>

                        <%!-- Step 3 --%>
                        <div id="drive-manual-auth" class="flex items-start gap-3">
                          <span class="w-6 h-6 rounded-full bg-indigo-600 text-white font-bold text-xs flex items-center justify-center shrink-0 mt-0.5 shadow-xs">
                            3
                          </span>
                          <div class="flex-1 space-y-2">
                            <label class="block text-xs font-semibold text-zinc-800 dark:text-zinc-200">
                              {gettext("Paste the browser address (URL) after authorizing")}
                            </label>

                            <div class="p-3 rounded-xl bg-amber-50/70 dark:bg-amber-950/30 border border-amber-200/70 dark:border-amber-900/50 space-y-1 text-[11px]">
                              <p class="font-semibold text-amber-900 dark:text-amber-200 flex items-center gap-1">
                                <.icon
                                  name="hero-information-circle"
                                  class="w-4 h-4 text-amber-600 shrink-0"
                                /> {gettext(
                                  "If you see \"This site can't be reached\" (this is expected)"
                                )}
                              </p>
                              <p class="text-amber-800 dark:text-amber-300 leading-relaxed">
                                {gettext(
                                  "After you click \"Allow\" on Google, the address bar of the other window goes to"
                                )}
                                <code class="font-mono bg-white/80 dark:bg-black/30 px-1 py-0.5 rounded">http://localhost:4000/...</code>
                                {gettext("and shows an error. This is normal. ")}<strong>{gettext("Copy the whole URL from that browser's address bar")}</strong>{gettext(
                                  ", paste it into the box below, and click \"Save and finish\" (pressing Enter in the box does the same)."
                                )}
                              </p>
                            </div>

                            <div class="relative">
                              <input
                                type="text"
                                name="drive_auth_code"
                                id="drive-auth-code"
                                value={@drive_auth_code}
                                autocomplete="off"
                                spellcheck="false"
                                placeholder={@drive_redirect_uri <> "?state=...&code=..."}
                                class="w-full px-3 py-2.5 rounded-lg border-2 border-dashed border-indigo-300 dark:border-indigo-700 bg-white dark:bg-zinc-950 text-xs font-mono focus:border-indigo-500 focus:border-solid shadow-xs"
                              />
                            </div>

                            <div class="flex flex-wrap items-center gap-3">
                              <button
                                type="button"
                                id="drive-auth-finish-btn"
                                phx-click="drive_auth_finish"
                                phx-disable-with={gettext("Authorizing…")}
                                disabled={String.trim(@drive_auth_code) == ""}
                                class="inline-flex items-center gap-1.5 px-3 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition disabled:opacity-40 disabled:cursor-not-allowed"
                              >
                                <.icon name="hero-check-circle" class="w-4 h-4" /> {gettext(
                                  "Save and finish"
                                )}
                              </button>
                              <%= case @drive_auth_result do %>
                                <% {:ok, message} -> %>
                                  <span
                                    id="drive-auth-result"
                                    class="text-[11px] text-emerald-600 dark:text-emerald-400"
                                  >
                                    {message}
                                  </span>
                                <% {:error, message} -> %>
                                  <span
                                    id="drive-auth-result"
                                    class="text-[11px] text-red-600 dark:text-red-400"
                                  >
                                    {message}
                                  </span>
                                <% _ -> %>
                              <% end %>
                            </div>

                            <p :if={@drive_on_server?} class="text-[11px] text-zinc-500">
                              {gettext(
                                "Note: If you are using a browser on the AskDrive server itself ("
                              )}<code class="font-mono">https://localhost:4443/</code>{gettext(
                                "), this completes automatically without pasting."
                              )}
                            </p>
                          </div>
                        </div>
                      </div>
                    <% end %>

                    <%!-- The OAuth client, set up once (here for this desk, or in the platform
                          settings for every desk) --%>
                    <details
                      id="drive-oauth-client"
                      open={@drive_client_open or not @drive_oauth_ready?}
                      class="rounded-xl bg-zinc-50 dark:bg-zinc-950/60 border border-zinc-200/60 dark:border-zinc-800"
                    >
                      <summary class="cursor-pointer px-3 py-2 text-xs font-medium text-zinc-700 dark:text-zinc-300">
                        {gettext(
                          "OAuth client settings (not needed when using the platform settings / per-desk override)"
                        )}{cond do
                          AskDrive.Drive.OAuth.desk_drive_client?() ->
                            gettext(": using this desk's settings")

                          @drive_oauth_ready? ->
                            gettext(": using the platform settings")

                          true ->
                            gettext(": not set")
                        end}
                      </summary>
                      <div id="drive-oauth-client-fields" class="px-3 pb-3 space-y-3">
                        <p
                          :if={not @drive_oauth_ready?}
                          id="drive-oauth-client-missing"
                          class="text-[11px] text-amber-700 dark:text-amber-300"
                        >
                          {gettext(
                            "To connect, you need a Google OAuth client (ID and secret). Register it under \"OAuth client for Google Drive sync\" in the platform settings to use it on every desk, or enter it below to set it for this desk only."
                          )}
                        </p>
                        <ol class="list-decimal pl-5 text-[11px] text-zinc-600 dark:text-zinc-400 space-y-1.5">
                          <li>
                            <a
                              href="https://console.cloud.google.com/apis/library/drive.googleapis.com"
                              target="_blank"
                              rel="noopener noreferrer"
                              class="underline text-indigo-600"
                            >{gettext("Enable the Google Drive API")}</a>
                          </li>
                          <li>
                            <a
                              href="https://console.cloud.google.com/apis/credentials/consent"
                              target="_blank"
                              rel="noopener noreferrer"
                              class="underline text-indigo-600"
                            >{gettext("OAuth consent screen")}</a>
                            {gettext("— create it:")}
                            <ul class="list-disc pl-4 mt-0.5 space-y-0.5 text-zinc-500">
                              <li>
                                <strong>{gettext("Google Workspace (organization)")}</strong>{gettext(
                                  ": set User type to “"
                                )}<strong>{gettext("Internal")}</strong>{gettext("”")}
                              </li>
                              <li>
                                <strong>{gettext("Personal Gmail (@gmail.com etc.)")}</strong>{gettext(
                                  ": set User type to “"
                                )}<strong>{gettext("External")}</strong>{gettext(
                                  "” and add the Gmail address to sync under “Test users”"
                                )}
                              </li>
                            </ul>
                          </li>
                          <li>
                            <a
                              href="https://console.cloud.google.com/apis/credentials/oauthclient"
                              target="_blank"
                              rel="noopener noreferrer"
                              class="underline text-indigo-600"
                            >{gettext("OAuth client ID")}</a>
                            {gettext(
                              "— create one (type \"Desktop app\"; no redirect URI registration needed)"
                            )}
                          </li>
                          <li>
                            {gettext(
                              "Enter the client ID and secret shown below, then click \"Save\" at the bottom of the card"
                            )}
                          </li>
                        </ol>
                        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                          <.input
                            field={@form[:drive_oauth_client_id]}
                            type="text"
                            label={gettext("OAuth client ID")}
                            placeholder="xxxxxxxx.apps.googleusercontent.com"
                          />
                          <.input
                            field={@form[:drive_oauth_client_secret]}
                            type="password"
                            value=""
                            label={
                              gettext("OAuth client secret (%{state})",
                                state: secret_state(@setting.drive_oauth_client_secret)
                              )
                            }
                          />
                        </div>
                        <.redirect_uri_help />
                        <div class="flex flex-wrap items-center gap-3">
                          <button
                            type="button"
                            id="test-drive-oauth-client-btn"
                            phx-click="test_oauth_client"
                            phx-value-scope="desk"
                            class="px-3 py-1.5 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium"
                          >
                            {gettext("Test connection (client in use)")}
                          </button>
                          <.client_test_result result={@oauth_client_test[:desk]} />
                        </div>
                      </div>
                    </details>
                  </div>
                <% end %>

                <%!-- Which folder to sync (moved here from the general settings form) --%>
                <div class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3">
                  <h3 class="font-semibold text-xs text-zinc-700 dark:text-zinc-300 flex items-center gap-1.5">
                    <.icon name="hero-folder" class="w-4 h-4 text-indigo-500" /> {gettext(
                      "Folder to sync"
                    )}
                  </h3>
                  <div class="space-y-3">
                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                      <.input
                        field={@form[:drive_folder_id]}
                        type="text"
                        label={gettext("Google Drive folder ID / URL")}
                        placeholder="https://drive.google.com/drive/folders/..."
                      />
                      <.input
                        field={@form[:drive_folder_name]}
                        type="text"
                        label={gettext("Folder display name (optional)")}
                      />
                    </div>
                    <div class="flex flex-wrap items-center gap-3">
                      <button
                        type="submit"
                        id="save-drive-settings-btn"
                        class="inline-flex items-center gap-1.5 px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                      >
                        <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> {gettext("Save")}
                      </button>
                      <button
                        type="button"
                        id="test-drive-sync-btn"
                        phx-click="test_drive_sync"
                        disabled={@drive_sync_test == :running}
                        class="px-3 py-2 rounded-xl border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium transition disabled:opacity-50"
                      >
                        {if @drive_sync_test == :running,
                          do: gettext("Testing…"),
                          else: gettext("Test sync")}
                      </button>
                      <span class="text-[11px] text-zinc-500">
                        {gettext(
                          "Checks authentication and folder access, and lists the files that would be synced (nothing is ingested)."
                        )}
                      </span>
                    </div>
                  </div>
                  <div id="drive-sync-test-result">
                    <%= case @drive_sync_test do %>
                      <% {:ok, %{folder: folder, count: count, sample: sample}} -> %>
                        <div class="text-[11px] text-emerald-700 dark:text-emerald-400 space-y-1">
                          <p>
                            {gettext(
                              "Sync works (%{identity}). Files to sync in folder \"%{folder}\": %{count}",
                              identity: to_string(Accounts.drive_identity()),
                              folder: to_string(folder),
                              count: count
                            )}
                          </p>
                          <ul
                            :if={sample != []}
                            class="font-mono text-zinc-600 dark:text-zinc-400 list-disc pl-4"
                          >
                            <li :for={path <- sample}>{path}</li>
                            <li :if={count > length(sample)} class="list-none">
                              {gettext("… and %{count} more", count: count - length(sample))}
                            </li>
                          </ul>
                        </div>
                      <% {:error, message} -> %>
                        <p class="text-[11px] text-red-600 dark:text-red-400">{message}</p>
                      <% _ -> %>
                    <% end %>
                  </div>
                </div>
              </.form>
            </div>

            <%!-- Card 3: LLM Provider Settings --%>
            <div
              :if={@scope == :app}
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-5"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "LLM providers"
                  )}
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  {gettext(
                    "Answer generation and embedding can use different providers. Keeping embedding local avoids re-indexing, so we recommend switching only generation first."
                  )}
                </p>
              </div>

              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <%= for {role, label, provider, model} <- [
                      {:generation, gettext("Answer generation"), @generation_provider, LLM.generation_model(@setting)},
                      {:embedding, gettext("Embedding"), @embedding_provider, @setting.embed_model}
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
                        {if LLM.local?(provider), do: gettext("Local"), else: gettext("External API")}
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
                      {gettext("API key: %{key}", key: LLM.masked_api_key(provider, @setting))}
                    </div>

                    <div class="pt-1 flex items-center gap-2">
                      <button
                        type="button"
                        id={"test-#{role}-btn"}
                        phx-click="test_connection"
                        phx-value-role={role}
                        class="px-2.5 py-1 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-[11px] font-medium transition"
                      >
                        {gettext("Test connection")}
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
                  {gettext("An external API is in use.")}<strong>{gettext(
                    "Document text and questions are sent to the provider."
                  )}</strong>
                  {gettext("For confidential documents, switch back to Ollama or LM Studio.")}
                </span>
              </div>

              <p class="text-[11px] text-zinc-400">
                {gettext("Change these values in the System, OAuth and batch settings form below.")}
              </p>
            </div>

            <%!-- Card 4: System Settings Form --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-6">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-cog-6-tooth" class="w-5 h-5 text-indigo-600" />
                {if @scope == :platform,
                  do: gettext("Nightly batch hours"),
                  else: gettext("AI, Drive and chat settings")}
              </h2>

              <.form
                for={@form}
                id="settings-form"
                phx-change="settings_change"
                phx-submit="save_settings"
                class="space-y-5"
              >
                <%!-- LLM Provider Selection. The nightly batch and the chat summary each run on
                      a local LLM or a cloud API (spec F-821, F-415); only the chosen side's fields
                      are shown (F-833). The other side's are hidden, not removed, so their saved
                      values are kept and switching back doesn't mean retyping them. --%>
                <div
                  :if={@scope == :app}
                  id="llm-settings"
                  class="space-y-4 p-4 rounded-xl bg-zinc-50 dark:bg-zinc-950/60 border border-zinc-200/60 dark:border-zinc-800"
                >
                  <h3 class="font-semibold text-xs text-zinc-700 dark:text-zinc-300 flex items-center gap-1.5">
                    <.icon name="hero-cpu-chip" class="w-4 h-4 text-indigo-500" /> {gettext(
                      "LLM providers and models"
                    )}
                  </h3>

                  <%!-- Nightly batch (QA generation) --%>
                  <div id="batch-llm" class="space-y-3">
                    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                      <.input
                        field={@form[:batch_llm_mode]}
                        type="select"
                        label={gettext("Run the nightly batch (QA generation) on")}
                        options={[{gettext("Local LLM"), "local"}, {gettext("Cloud API"), "cloud"}]}
                      />
                      <p class="sm:col-span-2 text-[11px] text-zinc-500 leading-relaxed sm:pt-6">
                        {if @llm_view.batch == "cloud",
                          do:
                            gettext(
                              "A cloud API is more accurate and faster, but at night the text of every chunk is sent to the API provider and billed by usage."
                            ),
                          else:
                            gettext(
                              "Generates with Ollama or LM Studio on this server. Documents are not sent outside your organization."
                            )}
                      </p>
                    </div>

                    <div
                      id="batch-local-fields"
                      class={[
                        "grid grid-cols-1 sm:grid-cols-2 gap-4",
                        @llm_view.batch != "local" && "hidden"
                      ]}
                    >
                      <.input
                        field={@form[:llm_provider]}
                        type="select"
                        label={gettext("Local LLM provider")}
                        options={provider_options(llm_providers_for("local"))}
                      />
                      <%= if @llm_view.local == "ollama" do %>
                        <.ollama_model_field
                          field={@form[:batch_model]}
                          kind={:generation}
                          catalog={@ollama_catalog}
                          label={gettext("Local LLM model name")}
                          required={@llm_view.batch == "local"}
                        />
                      <% else %>
                        <.input
                          field={@form[:batch_model]}
                          type="text"
                          label={gettext("Local LLM model name")}
                        />
                      <% end %>
                    </div>

                    <div
                      id="batch-cloud-fields"
                      class={[
                        "grid grid-cols-1 sm:grid-cols-3 gap-4",
                        @llm_view.batch != "cloud" && "hidden"
                      ]}
                    >
                      <.input
                        field={@form[:cloud_llm_provider]}
                        type="select"
                        label={gettext("Cloud API provider")}
                        options={provider_options(llm_providers_for("cloud"))}
                      />
                      <%!-- The provider's own model list (F-834); typed by hand while it
                            loads or when it can't be had (no API key yet, unreachable) --%>
                      <div id="cloud-llm-model-field">
                        <%= case Map.get(@cloud_models, @llm_view.cloud) do %>
                          <% {:ok, [_ | _] = models} -> %>
                            <.input
                              field={@form[:cloud_llm_model]}
                              type="select"
                              label={gettext("Cloud API model name")}
                              prompt={gettext("Choose a model")}
                              options={
                                AskDrive.LLM.CloudModels.options(
                                  models,
                                  if(to_string(@form[:cloud_llm_provider].value) == @llm_view.cloud,
                                    do: @form[:cloud_llm_model].value
                                  )
                                )
                              }
                            />
                          <% {:documented, models, why} -> %>
                            <%!-- the key may not list models: the manual's as suggestions,
                                  any name can still be typed --%>
                            <.input
                              field={@form[:cloud_llm_model]}
                              type="text"
                              label={gettext("Cloud API model name")}
                              placeholder={gettext("Choose from the suggestions or type a name")}
                              list="cloud-llm-model-suggestions"
                              autocomplete="off"
                            />
                            <datalist id="cloud-llm-model-suggestions">
                              <option :for={{id, label} <- models} value={id}>{label}</option>
                            </datalist>
                            <p
                              id="cloud-models-status"
                              class="-mt-1 text-[11px] text-zinc-500 leading-snug"
                            >
                              {if why == :no_list,
                                do:
                                  gettext(
                                    "Agent Platform gives no model list for an API key, so the suggestions are the models in Gemini's manual (October 2026). A model that isn't suggested can be typed; not every model is offered in every location or in express mode."
                                  ),
                                else:
                                  gettext(
                                    "This API key may not list models (its restrictions in the Google Cloud console), so the suggestions are the models in Gemini's manual (October 2026). A model that isn't suggested can be typed."
                                  )}
                            </p>
                          <% other -> %>
                            <.input
                              field={@form[:cloud_llm_model]}
                              type="text"
                              label={gettext("Cloud API model name")}
                              placeholder={gettext("e.g. a Gemini model name")}
                            />
                            <p
                              :if={other}
                              id="cloud-models-status"
                              class="-mt-1 text-[11px] text-zinc-500 leading-snug"
                            >
                              {case other do
                                :loading -> gettext("Loading the model list…")
                                {:ok, []} -> gettext("The provider listed no models.")
                                {:error, message} -> message
                              end}
                            </p>
                        <% end %>
                        <button
                          type="button"
                          id="refresh-cloud-models"
                          phx-click="refresh_cloud_models"
                          disabled={Map.get(@cloud_models, @llm_view.cloud) == :loading}
                          class="mt-1 inline-flex items-center gap-1 text-[11px] font-medium text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 dark:hover:text-indigo-300 disabled:opacity-50 disabled:cursor-wait transition"
                        >
                          <.icon
                            name="hero-arrow-path"
                            class={[
                              "w-3.5 h-3.5",
                              Map.get(@cloud_models, @llm_view.cloud) == :loading && "animate-spin"
                            ]}
                          />
                          {gettext("Refresh list")}
                        </button>
                      </div>
                      <.input
                        field={@form[:llm_max_tokens]}
                        type="number"
                        label={gettext("Max generation tokens")}
                        min="1"
                      />
                    </div>

                    <.provider_connection
                      :if={@llm_view.connection_at[@llm_view.batch_provider] == :batch}
                      provider={@llm_view.batch_provider}
                      form={@form}
                      setting={@setting}
                    />
                  </div>

                  <%!-- Chat answers can use their own (fast, cloud) provider while the
                        nightly batch keeps generating locally (spec F-415). --%>
                  <div
                    id="chat-summary-llm"
                    class="space-y-3 pt-3 border-t border-zinc-200/60 dark:border-zinc-800"
                  >
                    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                      <.input
                        type="select"
                        id="chat-summary-mode"
                        name="setting[chat_summary_mode]"
                        value={@llm_view.chat}
                        label={gettext("Run the chat summary on")}
                        options={[
                          {gettext("Same as the nightly batch"), "same"},
                          {gettext("Local LLM"), "local"},
                          {gettext("Cloud API"), "cloud"}
                        ]}
                      />
                      <.input
                        :if={@llm_view.chat != "same"}
                        field={@form[:chat_summary_provider]}
                        type="select"
                        label={
                          if(@llm_view.chat == "cloud",
                            do: gettext("Chat summary cloud API provider"),
                            else: gettext("Chat summary local LLM provider")
                          )
                        }
                        options={provider_options(llm_providers_for(@llm_view.chat))}
                      />
                      <%= if @llm_view.chat_provider == "ollama" do %>
                        <.ollama_model_field
                          field={@form[:chat_summary_model]}
                          kind={:generation}
                          catalog={@ollama_catalog}
                          label={gettext("Chat summary model name")}
                          prompt={gettext("Same as the nightly batch model")}
                        />
                      <% else %>
                        <.input
                          field={@form[:chat_summary_model]}
                          type="text"
                          label={gettext("Chat summary model name")}
                          placeholder={gettext("Blank: the nightly batch model")}
                        />
                      <% end %>
                    </div>
                    <%= if @llm_view.chat != "same" do %>
                      <.provider_connection
                        :if={@llm_view.connection_at[@llm_view.chat_provider] == :chat}
                        provider={@llm_view.chat_provider}
                        form={@form}
                        setting={@setting}
                      />
                      <p
                        :if={@llm_view.connection_at[@llm_view.chat_provider] != :chat}
                        class="text-[11px] text-zinc-500"
                      >
                        {gettext(
                          "The connection for %{provider} is set above, under the nightly batch.",
                          provider: LLM.label(@llm_view.chat_provider)
                        )}
                      </p>
                    <% end %>
                    <p class="text-[11px] text-zinc-500 leading-relaxed">
                      {if @llm_view.chat_side == "cloud",
                        do:
                          gettext(
                            "Summarizes with a cloud API. Questions and the retrieved excerpts are sent to the API provider."
                          ),
                        else:
                          gettext(
                            "Summarizes with a local LLM. Questions and excerpts are not sent outside your organization."
                          )}
                      {if @llm_view.chat != "same",
                        do:
                          gettext(
                            "When using a different provider from the nightly batch, enter a model name."
                          )}
                    </p>
                  </div>

                  <%!-- How the chat summary answers (spec F-432). Every style keeps the
                        grounding rules: excerpts only, [n] citations, "not found" answer. --%>
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    <.input
                      field={@form[:chat_answer_style]}
                      type="select"
                      label={gettext("Chat summary answer style")}
                      options={ChatSummary.style_options()}
                    />
                    <div class="sm:col-span-2 sm:pt-6 space-y-1">
                      <ul id="chat-answer-styles" class="space-y-0.5">
                        <li
                          :for={{label, style} <- ChatSummary.style_options()}
                          class={[
                            "text-[11px] leading-relaxed transition-colors",
                            if(to_string(@form[:chat_answer_style].value) == style,
                              do: "text-zinc-800 font-medium",
                              else: "text-zinc-500"
                            )
                          ]}
                        >
                          {label}: {ChatSummary.style_description(style)}
                        </li>
                      </ul>
                      <p class="text-[11px] text-zinc-500 leading-relaxed">
                        {gettext(
                          "Every style answers only from the excerpts, adds source numbers such as [1], and says it could not confirm the answer in the documents when the excerpts do not answer the question. Small local models often ignore instructions other than Concise (tone, length), so a cloud API (Gemini etc.) is recommended."
                        )}
                      </p>
                    </div>
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 pt-3 border-t border-zinc-200/60 dark:border-zinc-800">
                    <.input
                      field={@form[:embed_provider]}
                      type="select"
                      label={gettext("Embedding provider")}
                      options={provider_options(LLM.embedding_providers())}
                    />
                    <%= if @llm_view.embed == "ollama" do %>
                      <.ollama_model_field
                        field={@form[:embed_model]}
                        kind={:embedding}
                        catalog={@ollama_catalog}
                        label={gettext("Embedding model name")}
                        default={LLM.embedding_model(@setting)}
                        required
                      />
                    <% else %>
                      <.input
                        field={@form[:embed_model]}
                        type="text"
                        label={gettext("Embedding model name")}
                      />
                    <% end %>
                    <.input
                      field={@form[:embedding_dim]}
                      type="number"
                      label={gettext("Embedding dimensions")}
                      min="64"
                      max="4096"
                    />
                  </div>
                  <.provider_connection
                    :if={@llm_view.connection_at[@llm_view.embed] == :embed}
                    provider={@llm_view.embed}
                    form={@form}
                    setting={@setting}
                  />
                  <p
                    :if={@llm_view.connection_at[@llm_view.embed] != :embed}
                    class="-mt-2 text-[11px] text-zinc-500"
                  >
                    {gettext("The connection for %{provider} is set above.",
                      provider: LLM.label(@llm_view.embed)
                    )}
                  </p>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:llm_temperature]}
                      type="number"
                      step="0.1"
                      min="0.0"
                      max="2.0"
                      label={gettext("Temperature (blank: provider default)")}
                    />
                  </div>

                  <p
                    :if={@llm_view.embed == "ollama"}
                    id="ollama-embedding-dim-note"
                    class="text-[11px] text-zinc-500 leading-relaxed"
                  >
                    {gettext(
                      "With an Ollama model, the dimensions are set to the model's own when saving (e.g. bge-m3: 1024)."
                    )}
                  </p>

                  <p class="text-[11px] text-amber-700 dark:text-amber-300 leading-relaxed">
                    <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5 inline" />
                    {gettext(
                      "Changing the embedding model or dimensions recreates the vector table and discards all existing vectors. Tier 1 / Tier 2 do not work until the next nightly batch re-embeds every chunk."
                    )}
                  </p>
                </div>

                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <.input
                    :if={@scope == :app}
                    field={@form[:tier1_threshold]}
                    type="number"
                    step="0.01"
                    min="0.5"
                    max="1.0"
                    label={
                      gettext(
                        "Similarity threshold for instant QA answers (Tier 1) (default 0.90; lower answers more often from generated QA pairs, higher sends more to summary and excerpts)"
                      )
                    }
                  />
                </div>

                <div :if={@scope == :platform} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <.input
                    field={@form[:batch_start_hour]}
                    type="number"
                    label={gettext("Automatic run start hour (0–23, default 0)")}
                    min="0"
                    max="23"
                  />
                  <.input
                    field={@form[:batch_end_hour]}
                    type="number"
                    label={gettext("Latest hour an automatic run can start (0–23, default 7)")}
                    min="0"
                    max="23"
                  />
                  <.input
                    field={@form[:batch_deadline_hour]}
                    type="number"
                    label={
                      gettext(
                        "Batch cut-off hour (0–23, default 8; a running batch stops QA generation at this hour)"
                      )
                    }
                    min="0"
                    max="23"
                  />
                  <p
                    id="night-order-help"
                    class="sm:col-span-2 text-[11px] text-zinc-500 leading-relaxed"
                  >
                    {gettext(
                      "With several desks, the nightly run goes one desk at a time in two stages. (1) Ingestion (sync, text extraction, embedding) for every desk, starting with the desk with the lowest share ingested. (2) QA pair generation, starting with the desk with the lowest share generated. The time left before the cut-off is split between desks by the number of chunks still to generate, and time left over by a desk that finishes early goes to the next one."
                    )}
                  </p>
                </div>

                <.input
                  :if={@scope == :app}
                  field={@form[:maintenance_message]}
                  type="text"
                  label={gettext("Maintenance notice message")}
                />

                <div
                  :if={@scope == :app}
                  class="pt-2 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3"
                >
                  <%!-- On/off switches apply at once; 「設定を保存」 saves only values (F-206) --%>
                  <AskDriveWeb.FeatureToggle.toggle
                    id="toggle-auto-batch"
                    feature="auto_batch"
                    on={@setting.auto_batch_enabled}
                    label={gettext("Nightly automatic run")}
                    hint={
                      gettext(
                        "Runs Google Drive sync, ingestion and QA generation automatically in the night window. Manual runs work even when off. New desks start off while being set up."
                      )
                    }
                  />
                  <AskDriveWeb.FeatureToggle.toggle
                    id="toggle-maintenance"
                    feature="maintenance_mode"
                    on={@setting.maintenance_mode}
                    label={gettext("Maintenance mode")}
                    hint={gettext("Stops the chat screen and shows the notice message above")}
                    confirm_on={
                      gettext(
                        "Maintenance mode makes this desk's chat unavailable immediately. Continue?"
                      )
                    }
                  />
                  <AskDriveWeb.FeatureToggle.toggle
                    id="toggle-serve-stale"
                    feature="serve_stale_qa"
                    on={@setting.serve_stale_qa}
                    label={gettext("Serve invalidated (stale) QA pairs with a warning")}
                  />
                  <AskDriveWeb.FeatureToggle.toggle
                    id="toggle-daytime-llm"
                    feature="daytime_llm"
                    on={@setting.daytime_llm_enabled}
                    label={gettext("Allow LLM generation during business hours as an exception")}
                    hint={gettext("Watch RAM usage")}
                  />
                  <AskDriveWeb.FeatureToggle.toggle
                    id="toggle-chat-summary"
                    feature="chat_summary"
                    on={Map.get(@setting, :chat_summary_enabled, true)}
                    label={gettext("Show an AI summary of search results in chat")}
                    hint={
                      gettext(
                        "Uses the chat summary provider above. With a cloud provider, questions and excerpts are sent outside your organization"
                      )
                    }
                  />
                </div>

                <div class="pt-4 flex justify-end">
                  <button
                    type="submit"
                    id="save-settings-btn"
                    data-confirm={
                      @scope == :app &&
                        gettext(
                          "Save the settings? If you changed the embedding model or dimensions, the vector index is recreated and everything must be re-embedded. Continue?"
                        )
                    }
                    class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                  >
                    {gettext("Save settings")}
                  </button>
                </div>
              </.form>
            </div>

            <AskDriveWeb.OllamaPanel.ollama_card
              :if={@scope == :platform}
              status={@ollama_runtime}
              needed={@ollama_needed}
              install={@ollama_install}
              starting={@ollama_starting}
              overview={@ollama_overview}
              pulls={@ollama_pulls}
            />

            <%!-- HTTPS / SSL certificate (spec 6.10) --%>
            <div
              :if={@scope == :platform}
              id="ssl-settings"
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-lock-closed" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "HTTPS (SSL certificate)"
                  )}
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  {gettext(
                    "Traffic is encrypted with HTTPS (port %{https_port}). Access over HTTP (port %{http_port}) is redirected to HTTPS (HTTP is still accepted from the proxies set under Ports and reverse proxies below).",
                    https_port: AskDrive.SSL.https_port(),
                    http_port: AskDrive.SSL.http_port()
                  )}
                </p>
              </div>

              <%= if AskDrive.SSL.enabled?() do %>
                <% cert = AskDrive.SSL.current() || %{} %>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs">
                  <div>
                    <span class="text-zinc-400 block">{gettext("Certificate in use")}</span>
                    <span class="font-medium text-zinc-800 dark:text-zinc-200">
                      {case cert["source"] do
                        "custom" ->
                          gettext("Custom certificate")

                        "letsencrypt" ->
                          if cert["acme_staging"],
                            do:
                              gettext("Let's Encrypt (staging, for testing; browsers show a warning)"),
                            else: gettext("Let's Encrypt (auto-renewed)")

                        "self_signed" ->
                          gettext("Self-signed certificate (browsers show a warning)")

                        _ ->
                          gettext("Unknown")
                      end}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">{gettext("Expiry date")}</span>
                    <span class="font-mono">{format_cert_time(cert["not_after"])}</span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">{gettext("Subject / issuer")}</span>
                    <span class="font-mono break-all">{cert["subject"]} / {cert["issuer"]}</span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">{gettext("Host names covered")}</span>
                    <span class="font-mono break-all">{Enum.join(cert["names"] || [], ", ")}</span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">HSTS</span>
                    <span>{if AskDrive.SSL.hsts?(),
                      do: gettext("On (the certificate is trusted)"),
                      else:
                        gettext("Off (not sent while the certificate is self-signed or for testing)")}</span>
                  </div>
                </div>

                <p class="text-[11px] text-amber-700 dark:text-amber-300 bg-amber-50 dark:bg-amber-950/40 border border-amber-200 dark:border-amber-900 rounded-lg px-3 py-2">
                  {gettext(
                    "While the admin screen is open without login (POC), anyone on the LAN can replace the certificate. Turn on login before exposing it to the internet."
                  )}
                </p>

                <form
                  id="ssl-upload-form"
                  phx-submit="check_ssl"
                  phx-change="ssl_upload_change"
                  class="space-y-3"
                >
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
                    <label class="space-y-1">
                      <span class="block font-medium">{gettext("Certificate (PEM, required)")}</span>
                      <.live_file_input upload={@uploads.ssl_cert} class={ssl_file_input_class()} />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">{gettext("Private key (PEM, required)")}</span>
                      <.live_file_input upload={@uploads.ssl_key} class={ssl_file_input_class()} />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">{gettext(
                        "Intermediate certificate (PEM, optional)"
                      )}</span>
                      <.live_file_input upload={@uploads.ssl_chain} class={ssl_file_input_class()} />
                    </label>
                  </div>
                  <div
                    :for={
                      {name, upload} <- [
                        ssl_cert: @uploads.ssl_cert,
                        ssl_key: @uploads.ssl_key,
                        ssl_chain: @uploads.ssl_chain
                      ]
                    }
                    class="text-[11px] text-red-600"
                  >
                    <p :for={err <- upload_errors(upload)}>{name}: {upload_error_label(err)}</p>
                    <p :for={entry <- upload.entries} :if={upload_errors(upload, entry) != []}>
                      {entry.client_name}: {Enum.map_join(
                        upload_errors(upload, entry),
                        "、",
                        &upload_error_label/1
                      )}
                    </p>
                  </div>
                  <label class="block text-xs space-y-1 max-w-md">
                    <span class="block font-medium">{gettext(
                      "Public host name (optional; if given, checks that the certificate covers it)"
                    )}</span>
                    <input
                      type="text"
                      name="ssl_hostname"
                      placeholder={gettext("e.g. askdrive.example.com")}
                      class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 font-mono"
                    />
                  </label>
                  <div class="flex flex-wrap gap-2">
                    <button
                      type="submit"
                      id="check-ssl-btn"
                      class="px-4 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium"
                    >
                      {gettext("Verify")}
                    </button>
                    <button
                      :if={AskDrive.SSL.current()["source"] != "self_signed"}
                      type="button"
                      id="reset-self-signed-btn"
                      phx-click="reset_self_signed"
                      data-confirm={
                        gettext(
                          "Stop using the custom certificate and go back to a self-signed one? Browsers will show a certificate warning."
                        )
                      }
                      class="px-4 py-2 rounded-lg text-xs text-zinc-500 underline"
                    >
                      {gettext("Revert to self-signed certificate")}
                    </button>
                  </div>
                </form>

                <%= case @ssl_check do %>
                  <% {:ok, info, _pem} -> %>
                    <div
                      id="ssl-check-ok"
                      class="text-xs rounded-lg border border-emerald-200 bg-emerald-50 dark:bg-emerald-950/40 dark:border-emerald-900 px-3 py-2 space-y-1"
                    >
                      <p class="font-medium text-emerald-800 dark:text-emerald-200">
                        {gettext(
                          "Verification succeeded (certificate and key match, expiry, intermediate certificates, TLS connection test)."
                        )}
                      </p>
                      <p class="font-mono break-all">
                        {gettext("%{subject} (issuer: %{issuer})",
                          subject: to_string(info["subject"]),
                          issuer: to_string(info["issuer"])
                        )}
                      </p>
                      <p class="font-mono break-all">
                        {gettext("Host names: %{names}", names: Enum.join(info["names"], ", "))}
                      </p>
                      <p class="font-mono">
                        {gettext("Expires: %{date}", date: format_cert_time(info["not_after"]))}
                      </p>
                      <button
                        type="button"
                        id="apply-ssl-btn"
                        phx-click="apply_ssl"
                        data-confirm={
                          gettext(
                            "Save this certificate and restart HTTPS? Connections drop for a few seconds."
                          )
                        }
                        class="mt-1 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium"
                      >
                        {gettext("Save and apply (restarts HTTPS)")}
                      </button>
                    </div>
                  <% {:error, errors} -> %>
                    <div
                      id="ssl-check-error"
                      class="text-xs rounded-lg border border-red-200 bg-red-50 dark:bg-red-950/40 dark:border-red-900 px-3 py-2 space-y-1 text-red-700 dark:text-red-300"
                    >
                      <p class="font-medium">
                        {gettext("Verification failed. The certificate was not saved.")}
                      </p>
                      <p :for={e <- errors}>・{e}</p>
                    </div>
                  <% _ -> %>
                <% end %>

                <p :if={msg = last_ssl_result()} class="text-xs text-red-600">{msg}</p>

                <%!-- Let's Encrypt by DNS-01 through Value-Domain (spec F-1009 – F-1012) --%>
                <AskDriveWeb.AcmePanel.acme_section
                  setting={@setting}
                  form={@acme_form}
                  status={@acme_status}
                  dns_test={@acme_dns_test}
                />
              <% else %>
                <p class="text-xs text-zinc-500">
                  {gettext("HTTPS is off (ASK_DRIVE_SSL=false). Listening on HTTP.")}
                </p>
              <% end %>

              <%!-- Ports and trusted reverse proxies (spec F-1013) --%>
              <% net = AskDrive.Network.settings() %>
              <div
                id="network-settings"
                class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3"
              >
                <h3 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200">
                  {gettext("Ports and reverse proxies")}
                </h3>
                <p class="text-xs text-zinc-500 leading-relaxed">
                  {gettext(
                    "If a reverse proxy in front terminates HTTPS, enter its IP. HTTP from that IP is accepted without redirecting, and the X-Forwarded-For / X-Forwarded-Proto / X-Forwarded-Host headers it adds (CF-Connecting-IP for Cloudflare) are trusted (the user's real IP is used for lockouts and logs). HTTP from anywhere else is redirected to HTTPS. The decision uses the connecting IP, not the headers. Add HSTS on the proxy."
                  )}
                </p>
                <p class="text-xs text-zinc-600 dark:text-zinc-400">
                  {gettext("This screen connects from:")}
                  <span id="peer-ip" class="font-mono">{@peer_ip || gettext("Unknown")}</span>
                  <span
                    :if={@peer_ip && AskDrive.Network.trusted?(parse_ip(@peer_ip))}
                    class="text-emerald-700"
                  >
                    {gettext("(in the trusted proxies)")}
                  </span>
                </p>
                <form id="network-form" phx-submit="save_network" class="space-y-3">
                  <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 text-xs">
                    <label class="space-y-1">
                      <span class="block font-medium">{gettext("HTTPS port")}</span>
                      <input
                        type="number"
                        name="network[https_port]"
                        value={net.https_port}
                        min="1"
                        max="65535"
                        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                      />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">{gettext("HTTP port")}</span>
                      <input
                        type="number"
                        name="network[http_port]"
                        value={net.http_port}
                        min="1"
                        max="65535"
                        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                      />
                    </label>
                    <label class="space-y-1 col-span-2">
                      <span class="block font-medium">
                        {gettext(
                          "IPs of proxies to accept HTTP from (comma-separated; ranges like 10.0.0.0/24; blank: off)"
                        )}
                      </span>
                      <input
                        type="text"
                        name="network[trusted_proxies]"
                        value={Enum.join(net.trusted_proxies, ", ")}
                        placeholder={gettext("e.g. 127.0.0.1, 192.168.1.10")}
                        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
                      />
                    </label>
                  </div>
                  <p class="text-[11px] text-zinc-400">
                    {gettext(
                      "Changing a port restarts AskDrive's listener (a few seconds). If it cannot start on the new port, it goes back. If you get locked out, run"
                    )}
                    <code class="font-mono">./app.sh network ports-reset</code>
                    / <code class="font-mono">./app.sh network proxy-off</code>
                    {gettext(
                      "on the server to undo it. Also change the target port on the proxy (Cloudflare Tunnel etc.)."
                    )}
                  </p>
                  <div class="flex justify-end">
                    <button
                      type="submit"
                      id="save-network-btn"
                      data-confirm={
                        gettext(
                          "Save the port and proxy settings? If you change a port, reopen the screen at the new port's URL."
                        )
                      }
                      class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                    >
                      {gettext("Save")}
                    </button>
                  </div>
                </form>
                <p
                  :if={match?({:error, _}, AskDrive.Network.last_result())}
                  id="network-last-error"
                  class="text-xs text-red-600"
                >
                  {AskDrive.Network.last_result() |> elem(1) |> Enum.join("／")}
                </p>
              </div>

              <%!-- API gateway in front (spec F-1014) --%>
              <AskDriveWeb.GatewayPanel.gateway_section
                gw={@gateway_settings}
                peer_ip={@peer_ip}
                via_gateway={AskDrive.Gateway.valid_secret?(@gateway_header)}
              />
            </div>

            <%!-- Access only from devices with a certificate issued here (spec 6.14) --%>
            <% cc_mode = @client_cert_mode %>
            <div
              :if={@scope == :platform}
              id="client-cert-settings"
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-finger-print" class="w-5 h-5 text-indigo-600" /> {gettext(
                    "Restrict access to devices with a certificate"
                  )}
                  <span
                    id="client-cert-mode"
                    class={[
                      "text-[11px] font-medium px-2 py-0.5 rounded-full",
                      case cc_mode do
                        "enforce" ->
                          "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

                        "monitor" ->
                          "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

                        _ ->
                          "bg-zinc-100 text-zinc-500 dark:bg-zinc-800"
                      end
                    ]}
                  >
                    {case cc_mode do
                      "enforce" -> gettext("Enforce")
                      "monitor" -> gettext("Monitor")
                      _ -> gettext("Off")
                    end}
                  </span>
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  {gettext(
                    "Only devices (browsers) with a certificate issued by AskDrive can open any screen, including the login screen. Certificates are issued per group (such as a department) and handed out as password-protected .p12 files. Who the user is is still checked by login; the certificate is an extra check that the device is one you handed it to. Roll out in the order Off, Monitor, Enforce. Monitor asks for a certificate and logs it, but refuses no one."
                  )}
                </p>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  {gettext(
                    "This assumes clients connect over HTTPS directly (if a reverse proxy terminates TLS, certificates do not reach AskDrive through it). If you get locked out, run"
                  )}
                  <code class="font-mono">./app.sh mtls off</code>
                  {gettext("on the server, or open the screen from the server itself (localhost).")}
                </p>
              </div>

              <%!-- The office LAN (F-1408): no certificate needed from there --%>
              <form
                id="client-cert-lan-form"
                phx-submit="save_client_cert_lan"
                class="space-y-2 text-xs"
              >
                <label class="block space-y-1">
                  <span class="block font-medium text-zinc-700 dark:text-zinc-300">
                    {gettext(
                      "Office LAN IP addresses and ranges (connections from these can open the login screen and the screens after login without a certificate; comma-separated; ranges like 192.168.0.0/16)"
                    )}
                  </span>
                  <input
                    type="text"
                    name="lan"
                    value={Enum.join(@client_cert_lan, ", ")}
                    placeholder={gettext("e.g. 192.168.0.0/16, 10.0.0.0/8")}
                    class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
                  />
                </label>
                <p class="text-zinc-500">
                  {gettext(
                    "Behind a reverse proxy, add the proxy under Ports and reverse proxies. Otherwise every connection appears to come from the proxy (the office LAN) and gets in without a certificate."
                  )}
                </p>
                <div class="flex justify-end">
                  <button
                    type="submit"
                    id="save-client-cert-lan-btn"
                    class="px-4 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 font-medium"
                  >
                    {gettext("Save")}
                  </button>
                </div>
              </form>

              <p id="this-connection-cert" class="text-xs text-zinc-600 dark:text-zinc-400">
                {gettext("This connection's certificate:")}
                {case AskDrive.ClientCerts.check(@peer_cert) do
                  {:ok, cert} ->
                    gettext("Valid (group %{group})", group: cert.group.name)

                  :none ->
                    if(cc_mode == "off",
                      do: gettext("(not checked while off)"),
                      else: gettext("None")
                    )

                  :revoked ->
                    gettext("Revoked")

                  :expired ->
                    gettext("Expired")

                  :unknown ->
                    gettext("Not issued by this AskDrive")
                end}
                <span
                  :if={AskDrive.Network.in_ranges?(parse_ip(@peer_ip), @client_cert_lan)}
                  id="this-connection-lan"
                  class="text-emerald-700"
                >
                  {gettext("(from the office LAN, so no certificate is needed)")}
                </span>
              </p>

              <div class="flex flex-wrap gap-2">
                <button
                  :for={
                    {mode, label} <- [
                      {"off", gettext("Off")},
                      {"monitor", gettext("Monitor")},
                      {"enforce", gettext("Enforce")}
                    ]
                  }
                  :if={mode != cc_mode}
                  id={"client-cert-mode-#{mode}"}
                  phx-click="set_client_cert_mode"
                  phx-value-mode={mode}
                  data-confirm={
                    case mode do
                      "enforce" ->
                        gettext(
                          "Switch to Enforce? Devices without a certificate can no longer open even the login screen."
                        )

                      "off" ->
                        gettext("Switch to Off? Devices without a certificate can get in again.")

                      _ ->
                        gettext(
                          "Switch to Monitor? Certificates are requested and logged, but no one is refused."
                        )
                    end
                  }
                  class="px-3 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium"
                >
                  {gettext("Switch to %{mode}", mode: label)}
                </button>
              </div>

              <div
                :if={@issued_cert}
                id="issued-cert"
                class="p-3 rounded-lg bg-indigo-50 dark:bg-indigo-950/40 border border-indigo-200 dark:border-indigo-900 text-xs space-y-1"
              >
                <p class="font-semibold">
                  {if @issued_cert.again?,
                    do: gettext("Certificate %{name} is ready to download", name: @issued_cert.name),
                    else: gettext("Issued certificate %{name}", name: @issued_cert.name)}
                </p>
                <p class="text-zinc-600 dark:text-zinc-400">
                  {gettext("Devices and browsers show it as %{name}. Expires: %{expires}",
                    name: @issued_cert.name,
                    expires:
                      (@issued_cert.expires && AskDrive.Clock.format(@issued_cert.expires, "%Y-%m-%d")) ||
                        ""
                  )}
                </p>
                <p>
                  {gettext("Password:")}
                  <span id="issued-cert-password" class="font-mono text-sm select-all">{@issued_cert.password}</span>
                  {gettext("(send it separately from the .p12 file)")}
                </p>
                <p>
                  {gettext(
                    "Download the file for the recipient's device (valid for 10 minutes; each installs without admin rights on the device; you can also get it later with Download again in the list):"
                  )}
                </p>
                <div class="flex flex-wrap gap-2">
                  <a
                    :for={
                      {format, label} <- [
                        {"windows", gettext("For Windows (.pfx)")},
                        {"macos", gettext("For macOS (.p12)")},
                        {"ios", gettext("For iPhone / iPad (.mobileconfig)")},
                        {"android", gettext("For Android (.p12)")}
                      ]
                    }
                    id={"issued-cert-download-#{format}"}
                    href={"/admin/client-certs/#{@issued_cert.token}?format=#{format}"}
                    class="inline-block px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium"
                  >
                    {label}
                  </a>
                </div>
              </div>

              <div class="space-y-3">
                <h3 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200">
                  {gettext("Groups and certificates")}
                </h3>
                <div
                  :for={group <- @client_cert_groups}
                  id={"cert-group-#{group.id}"}
                  class="p-3 rounded-xl border border-zinc-200/80 dark:border-zinc-800 space-y-2 text-xs"
                >
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <span class="font-medium text-zinc-800 dark:text-zinc-200">{group.name}</span>
                    <div class="flex gap-2">
                      <button
                        id={"issue-cert-#{group.id}"}
                        type="button"
                        phx-click={JS.toggle(to: "#issue-cert-form-#{group.id}")}
                        class="px-2.5 py-1 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium"
                      >
                        {gettext("Issue certificate…")}
                      </button>
                      <button
                        :if={Enum.all?(group.certs, & &1.revoked_at)}
                        phx-click="delete_client_cert_group"
                        phx-value-group_id={group.id}
                        data-confirm={gettext("Delete group %{name}?", name: group.name)}
                        class="px-2.5 py-1 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800"
                      >
                        {gettext("Delete")}
                      </button>
                    </div>
                  </div>
                  <% today = AskDrive.Clock.local_today()
                  latest = AskDrive.ClientCerts.latest_expiry() %>
                  <form
                    id={"issue-cert-form-#{group.id}"}
                    phx-submit="issue_client_cert"
                    class="hidden p-3 rounded-lg bg-zinc-50 dark:bg-zinc-900/60 grid gap-2 sm:grid-cols-3"
                  >
                    <input type="hidden" name="group_id" value={group.id} />
                    <label class="space-y-1">
                      <span class="block text-zinc-600 dark:text-zinc-400">{gettext(
                        "Note (optional, up to 40 characters)"
                      )}</span>
                      <input
                        type="text"
                        name="label"
                        maxlength="40"
                        placeholder={gettext("e.g. Reception PC")}
                        class="w-full px-2 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                      />
                    </label>
                    <label class="space-y-1">
                      <span class="block text-zinc-600 dark:text-zinc-400">{gettext("Expiry date")}</span>
                      <input
                        type="date"
                        name="expires_on"
                        required
                        value={Date.add(today, 365)}
                        min={Date.add(today, 1)}
                        max={latest}
                        class="w-full px-2 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                      />
                    </label>
                    <label class="space-y-1">
                      <span class="block text-zinc-600 dark:text-zinc-400">{gettext(
                        "Password (optional)"
                      )}</span>
                      <input
                        type="text"
                        name="password"
                        autocomplete="off"
                        spellcheck="false"
                        placeholder={gettext("Blank: generated (16 characters)")}
                        class="w-full px-2 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
                      />
                    </label>
                    <p class="sm:col-span-3 text-[11px] text-zinc-500">
                      {gettext(
                        "Devices and browsers show %{name} (with a note: %{with_note}). The password is 8 to 64 ASCII letters, digits and symbols.",
                        name: AskDrive.ClientCerts.display_name(group.name, nil),
                        with_note: AskDrive.ClientCerts.display_name(group.name, gettext("note"))
                      )}
                    </p>
                    <div class="sm:col-span-3">
                      <button
                        type="submit"
                        id={"issue-cert-submit-#{group.id}"}
                        class="px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium"
                      >
                        {gettext("Issue")}
                      </button>
                    </div>
                  </form>
                  <table :if={group.certs != []} class="w-full text-left">
                    <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                      <tr :for={cert <- group.certs} id={"client-cert-#{cert.id}"}>
                        <td class="py-1">
                          <span class="font-mono">{String.slice(cert.serial, 0, 8)}</span>
                          <span :if={cert.label} class="ml-1 text-zinc-600 dark:text-zinc-300">
                            {cert.label}
                          </span>
                        </td>
                        <td class="py-1">
                          {gettext("Issued %{issued} · Expires %{expires}",
                            issued: AskDrive.Clock.format(cert.inserted_at, "%Y-%m-%d"),
                            expires:
                              (cert.not_after && AskDrive.Clock.format(cert.not_after, "%Y-%m-%d")) ||
                                ""
                          )}
                        </td>
                        <td class="py-1">
                          {gettext("Last used %{time}",
                            time:
                              if(cert.last_seen_at,
                                do: AskDrive.Clock.format(cert.last_seen_at, "%m/%d %H:%M"),
                                else: "—"
                              )
                          )}
                        </td>
                        <td class="py-1 text-right">
                          <%= if cert.revoked_at do %>
                            <span class="text-red-600">{gettext("Revoked %{date}",
                              date: AskDrive.Clock.format(cert.revoked_at, "%m/%d")
                            )}</span>
                          <% else %>
                            <button
                              :if={
                                cert.kept? &&
                                  (is_nil(cert.not_after) ||
                                     DateTime.compare(cert.not_after, DateTime.utc_now()) == :gt)
                              }
                              id={"redownload-cert-#{cert.id}"}
                              phx-click="redownload_client_cert"
                              phx-value-id={cert.id}
                              class="px-2 py-0.5 mr-1 rounded border border-indigo-300 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-50 dark:hover:bg-indigo-950/40"
                            >
                              {gettext("Download again")}
                            </button>
                            <button
                              id={"revoke-cert-#{cert.id}"}
                              phx-click="revoke_client_cert"
                              phx-value-id={cert.id}
                              data-confirm={
                                gettext(
                                  "Revoke this certificate? Devices that have it installed are locked out immediately."
                                )
                              }
                              class="px-2 py-0.5 rounded border border-red-300 text-red-700 hover:bg-red-50"
                            >
                              {gettext("Revoke")}
                            </button>
                          <% end %>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
                <form
                  id="new-cert-group-form"
                  phx-submit="create_client_cert_group"
                  class="flex gap-2 text-xs"
                >
                  <input
                    type="text"
                    name="name"
                    required
                    placeholder={gettext("Group name (e.g. Accounting)")}
                    class="flex-1 px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                  />
                  <button
                    type="submit"
                    class="px-4 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 font-medium"
                  >
                    {gettext("Add group")}
                  </button>
                </form>
                <p class="text-[11px] text-zinc-400">
                  {gettext(
                    "To replace certificates, issue and hand out new ones in the same group, then revoke the old ones once everyone has switched (both work in the meantime). If a certificate leaks, revoke it at once."
                  )}
                </p>
              </div>

              <div
                :if={cc_mode == "monitor" and @users_without_cert != []}
                id="users-without-cert"
                class="space-y-1"
              >
                <h3 class="font-semibold text-xs text-zinc-700 dark:text-zinc-300">
                  {gettext(
                    "Users who accessed without a certificate (monitoring; check before switching to Enforce)"
                  )}
                </h3>
                <p
                  :for={u <- @users_without_cert}
                  class="text-[11px] text-zinc-600 dark:text-zinc-400"
                >
                  {u.email}（{AskDrive.Clock.format(u.no_client_cert_seen_at, "%m/%d %H:%M")}）
                </p>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_async(:start_ollama, result, socket) do
    socket = socket |> assign(:ollama_starting, false) |> assign_ollama_runtime()

    case result do
      {:ok, ok} when ok in [:ok, :started] ->
        {:noreply, put_flash(socket, :info, gettext("Ollama is running."))}

      {:ok, {:error, reason}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Ollama didn't start: %{reason}", reason: inspect(reason))
         )}

      {:exit, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Ollama didn't start: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_async(:drive_sync_test, {:ok, result}, socket),
    do: {:noreply, assign(socket, :drive_sync_test, result)}

  def handle_async(:drive_sync_test, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(
         socket,
         :drive_sync_test,
         {:error, gettext("Sync test failed: %{reason}", reason: inspect(reason))}
       )}

  def handle_async({:cloud_models, provider}, {:ok, result}, socket),
    do:
      {:noreply,
       assign(socket, :cloud_models, Map.put(socket.assigns.cloud_models, provider, result))}

  def handle_async({:cloud_models, provider}, {:exit, reason}, socket) do
    result =
      {:error, gettext("Could not get the model list: %{reason}", reason: inspect(reason))}

    {:noreply,
     assign(socket, :cloud_models, Map.put(socket.assigns.cloud_models, provider, result))}
  end

  def handle_async(:acme_dns_test, {:ok, result}, socket),
    do: {:noreply, assign(socket, :acme_dns_test, result)}

  def handle_async(:acme_dns_test, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(
         socket,
         :acme_dns_test,
         {:error, gettext("Connection test failed: %{reason}", reason: inspect(reason))}
       )}

  # Which redirect URIs a 「ウェブ アプリケーション」 client needs (F-349); a 「デスクトップ
  # アプリ」 client needs none for Drive sync
  defp redirect_uri_help(assigns) do
    ~H"""
    <div class="text-[11px] text-zinc-500 space-y-1">
      <p>
        {gettext(
          "For Drive sync only, a client of type \"Desktop app\" is recommended (no redirect URI to register). For a client of type \"Web application\", register the following under \"Authorized redirect URIs\":"
        )}
      </p>
      <ul class="list-disc pl-5 font-mono text-indigo-600 dark:text-indigo-400">
        <li :for={uri <- AskDrive.Drive.OAuth.web_client_redirect_uris()} class="select-all">
          {uri}
        </li>
        <li class="select-all">
          https://&lt;{gettext("host name")}&gt;:{AskDrive.SSL.https_port()}/auth/google/callback
          <span class="font-sans text-zinc-500">{gettext("(when using Google login)")}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :result, :any, default: nil

  defp client_test_result(assigns) do
    ~H"""
    <%= case @result do %>
      <% {:ok, message} -> %>
        <span class="text-[11px] text-emerald-600 dark:text-emerald-400">{message}</span>
      <% {:error, message} -> %>
        <span class="text-[11px] text-red-600 dark:text-red-400">{message}</span>
      <% _ -> %>
    <% end %>
    """
  end

  # Takes the settings so the badge re-renders when they're saved (LiveView tracks assigns)
  defp oauth_status(_setting) do
    cond do
      not AskDrive.Drive.OAuth.client_configured?() -> :unset
      AskDrive.Drive.OAuth.login_enabled?() -> :login
      true -> :drive_only
    end
  end

  # Google takes a redirect URI on a real host name (a public top-level domain), not on a
  # bare IP address or a .local name — those need the paste instead
  defp google_accepts_host?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} ->
        false

      _ ->
        String.contains?(host, ".") and not String.ends_with?(host, ".local") and
          not String.ends_with?(host, ".localhost")
    end
  end

  defp google_accepts_host?(_), do: false

  # the Drive sync account must belong to the organization (as for the browser flow)
  defp drive_account_allowed(email) do
    domain = Settings.platform_setting!().allowed_domain

    cond do
      domain in [nil, ""] ->
        :ok

      is_binary(email) and
          String.ends_with?(String.downcase(email), "@" <> String.downcase(domain)) ->
        :ok

      true ->
        {:error, {:domain, domain}}
    end
  end

  defp drive_auth_error(:no_code),
    do:
      gettext(
        "No authorization code found. Paste the address of the page you see after allowing access, as it is."
      )

  defp drive_auth_error(:state_mismatch),
    do:
      gettext(
        "This address belongs to another authorization. Authorize again with \"Open Google's authorization page\" on this screen."
      )

  defp drive_auth_error({:denied, reason}),
    do: gettext("Google did not allow it (%{reason}).", reason: to_string(reason))

  defp drive_auth_error({:domain, domain}),
    do:
      gettext("Authorize with an account in the organization's domain (@%{domain}).",
        domain: domain
      )

  defp drive_auth_error(reason) when is_binary(reason),
    do:
      gettext(
        "Could not get a token: %{reason} (a code can be used only once; if it has expired, authorize again)",
        reason: reason
      )

  defp drive_auth_error(reason),
    do: gettext("Could not get a token: %{reason}", reason: inspect(reason))

  # Whether this desk can authorize Drive by OAuth: its own client (F-346) or the platform's
  defp assign_drive_mode(socket) do
    ready? = AskDrive.Drive.OAuth.drive_client_configured?()
    hint = socket.assigns[:drive_login_hint] || ""
    # How Google comes back after 接続 (F-348, F-350): to AskDrive itself when the browser
    # is on the server (loopback) or uses a host name Google accepts; otherwise to the
    # browser's own localhost, and the address is pasted.
    %{host: host, port: port, scheme: scheme} = socket.host_uri
    # the one redirect URI (F-351) names "localhost", so only a page opened as localhost gets
    # its session back on return
    on_server? = host == "localhost"

    redirect_mode =
      cond do
        on_server? -> :loopback
        google_accepts_host?(host) -> :host
        true -> :paste
      end

    redirect_uri =
      case redirect_mode do
        :loopback ->
          AskDrive.Drive.OAuth.manual_redirect_uri()

        :host ->
          "#{scheme}://#{host}#{if port in [80, 443], do: "", else: ":#{port}"}/auth/google/callback"

        :paste ->
          AskDrive.Drive.OAuth.manual_redirect_uri()
      end

    socket
    |> assign(:drive_oauth_ready?, ready?)
    |> assign(:drive_mode, socket.assigns.setting.drive_auth_mode)
    |> assign(:drive_login_hint, hint)
    |> assign(:drive_on_server?, on_server?)
    |> assign(:drive_redirect_mode, redirect_mode)
    |> assign(:drive_redirect_uri, redirect_uri)
    |> assign(:drive_client_id, elem(AskDrive.Drive.OAuth.drive_client(), 0))
    |> assign_new(:drive_client_open, fn -> false end)
    |> assign_new(:oauth_client_test, fn -> %{} end)
    |> assign_new(:drive_auth_code, fn -> "" end)
    |> assign_new(:drive_auth_result, fn -> nil end)
    |> then(fn socket ->
      # keep an authorization in progress (its state / PKCE verifier) across refreshes, as
      # long as it still goes back to the same place
      current = socket.assigns[:drive_auth]

      auth =
        cond do
          not ready? -> nil
          current && current.redirect_uri == redirect_uri -> current
          true -> new_drive_auth(socket, hint)
        end

      assign(socket, :drive_auth, auth)
    end)
  end

  defp new_drive_auth(socket, hint) do
    AskDrive.Drive.OAuth.manual_authorization(
      hint,
      socket.assigns[:app] && socket.assigns.app.slug,
      socket.assigns[:drive_redirect_uri]
    )
  end

  defp drive_sync_dry_run(folder_id, setting) do
    with {:ok, folder} <- Client.get_metadata(folder_id),
         {:ok, files} <- Client.list_files(folder_id) do
      {:ok,
       %{
         folder: folder["name"],
         count: length(files),
         sample: files |> Enum.map(& &1["path"]) |> Enum.sort() |> Enum.take(5)
       }}
    else
      {:error, "HTTP 404" <> _} ->
        {:error, folder_not_found_hint(setting)}

      {:error, reason} ->
        {:error, gettext("Could not read the sync folder: %{reason}", reason: inspect(reason))}
    end
  rescue
    e -> {:error, gettext("Sync test failed: %{reason}", reason: Exception.message(e))}
  end

  # A token alone proves only that Google accepted the key (and the delegation). What sync
  # actually needs is read access to the folder, which is exactly what failed with a bare
  # 404 when an org-only shared drive refused the service account — so check that too.
  defp check_drive_folder(%{drive_folder_id: folder_id}) when folder_id in [nil, ""] do
    {:ok,
     gettext(
       "Got a token (%{identity}). No sync folder is set, so reading the folder was not checked.",
       identity: to_string(Accounts.drive_identity())
     )}
  end

  defp check_drive_folder(%{drive_folder_id: folder_id} = setting) do
    case Client.get_metadata(folder_id) do
      {:ok, folder} ->
        {:ok,
         gettext("Connected (%{identity}). The sync folder \"%{folder}\" can be read.",
           identity: to_string(Accounts.drive_identity()),
           folder: to_string(folder["name"])
         )}

      {:error, "HTTP 404" <> _} ->
        {:error, folder_not_found_hint(setting)}

      {:error, reason} ->
        {:error,
         gettext("Got a token, but could not read the sync folder: %{reason}",
           reason: inspect(reason)
         )}
    end
  end

  defp folder_not_found_hint(%{drive_impersonate_email: subject})
       when is_binary(subject) and subject != "" do
    gettext(
      "Got a token, but %{user} has no permission to view the sync folder. Give that user access to the folder (or the shared drive).",
      user: subject
    )
  end

  defp folder_not_found_hint(_setting) do
    gettext(
      "Got a token, but the sync folder can't be read (Drive reports files you have no permission for as \"not found\"). Share the folder with the service account. If an organization-only shared drive doesn't let you add the service account, set the \"Access user\" below and use domain-wide delegation."
    )
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

  defp phase_label("sync"), do: gettext("Sync")
  defp phase_label("embed_chunks"), do: gettext("Ingestion")
  defp phase_label("generate"), do: gettext("Generation")
  defp phase_label(other), do: other

  defp item_status_label("created"), do: gettext("New")
  defp item_status_label("updated"), do: gettext("Updated")
  defp item_status_label("unchanged"), do: gettext("Unchanged")
  defp item_status_label("deleted"), do: gettext("Deleted")
  defp item_status_label("indexed"), do: gettext("Ingested")
  defp item_status_label("empty"), do: gettext("No text")
  defp item_status_label("skipped"), do: gettext("Skipped")
  defp item_status_label("failed"), do: gettext("Failed")
  defp item_status_label(other), do: other

  defp item_status_class("failed"),
    do: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"

  defp item_status_class(status) when status in ["indexed", "created", "updated"],
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

  defp item_status_class(status) when status in ["empty", "skipped", "deleted"],
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

  defp item_status_class(_), do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

  defp status_label("completed"), do: gettext("Completed")
  defp status_label("running"), do: gettext("Running")
  defp status_label("waiting"), do: gettext("Waiting for generation (ingested)")
  defp status_label("aborted"), do: gettext("Aborted (restart)")
  defp status_label("failed"), do: gettext("Failed")
  defp status_label("deadline_reached"), do: gettext("Out of time")
  defp status_label("stopped"), do: gettext("Stopped (manual)")
  defp status_label("skipped"), do: gettext("Not run (API key not set)")
  defp status_label(other), do: other

  defp status_class("completed"),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

  defp status_class("running"),
    do: "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300 animate-pulse"

  defp status_class("waiting"),
    do: "bg-indigo-50 text-indigo-700 dark:bg-indigo-950/50 dark:text-indigo-300"

  defp status_class("deadline_reached"),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

  defp status_class("skipped"),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

  defp status_class("stopped"),
    do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

  defp status_class(_), do: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"

  defp trigger_label("auto"), do: gettext("Auto")
  defp trigger_label(_), do: gettext("Manual")

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # An aborted run's finished_at is when the next boot noticed it, not when it stopped.
  defp duration_label(%{status: "aborted"}), do: gettext("— (aborted)")

  defp duration_label(%{started_at: s, finished_at: nil}) when not is_nil(s) do
    gettext("%{duration} so far", duration: format_seconds(DateTime.diff(DateTime.utc_now(), s)))
  end

  defp duration_label(%{started_at: s, finished_at: f}) when not is_nil(s) and not is_nil(f),
    do: format_seconds(DateTime.diff(f, s))

  defp duration_label(_), do: "—"

  # the newest run ended before finishing, and a re-run has something to do
  defp resumable?([%{status: status} | _], remaining)
       when status in ["failed", "stopped", "aborted", "deadline_reached"],
       do: remaining.documents + remaining.chunks + remaining.questions > 0

  defp resumable?(_runs, _remaining), do: false

  # Switching login on (F-1308) registers administrators; offer the platform administrators
  # named at setup, so turning it on is one click once a way to sign in exists (F-930)
  defp prefill_enable_auth_admins(socket) do
    emails =
      if socket.assigns.scope == :platform and AskDriveWeb.UserAuth.auth_disabled?(),
        do: Enum.map(Accounts.list_eligible_admins(), & &1.email),
        else: []

    if emails == [],
      do: socket,
      else:
        Phoenix.Component.update(
          socket,
          :ac,
          &Map.put(&1, "enable-auth-admin-email", %{
            value: Enum.join(emails, ", "),
            suggestions: []
          })
        )
  end

  # --- E-mail fields completed from the directory (spec F-1115) ---------------------

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :ac, :map, required: true
  attr :placeholder, :string, default: nil
  attr :required, :boolean, default: true

  # an e-mail field that suggests addresses from Secure LDAP while typing (the last address
  # when several are separated by commas); plain text otherwise
  defp email_input(assigns) do
    assigns =
      assign(assigns, :state, Map.get(assigns.ac, assigns.id, %{value: nil, suggestions: []}))

    ~H"""
    <div class="relative">
      <input
        type="text"
        id={@id}
        name={@name}
        value={@state.value}
        required={@required}
        placeholder={@placeholder}
        autocomplete="off"
        phx-keyup="ac_suggest"
        phx-value-field={@id}
        phx-debounce="300"
        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
      />
      <ul
        :if={@state.suggestions != []}
        id={@id <> "-suggestions"}
        class="absolute z-20 mt-1 w-full max-h-60 overflow-y-auto rounded-lg border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900 shadow-lg text-xs"
      >
        <li :for={u <- @state.suggestions}>
          <button
            type="button"
            phx-click="ac_pick"
            phx-value-field={@id}
            phx-value-email={u.email}
            class="w-full text-left px-3 py-2 hover:bg-indigo-50 dark:hover:bg-indigo-950/40"
          >
            <span class="font-medium text-zinc-800 dark:text-zinc-200">{u.name || u.email}</span>
            <span class="text-zinc-500 ml-1">{u.email}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # the address being typed: the part after the last separator
  defp split_last_address(value) do
    case Regex.run(~r/^(.*[\s,;、])?([^\s,;、]*)$/u, value || "") do
      [_, head, last] -> {head || "", last}
      [_, head] -> {head || "", ""}
      _ -> {"", value || ""}
    end
  end

  defp clear_ac(socket, field), do: Phoenix.Component.update(socket, :ac, &Map.delete(&1, field))

  # typos (F-1115): with Secure LDAP on, every address must exist in the directory
  defp check_directory(emails) do
    case AskDrive.Ldap.unknown_emails(Settings.platform_setting!(), emails) do
      {:ok, []} ->
        :ok

      {:ok, missing} ->
        {:error,
         gettext("Not found in the directory (Google Workspace): %{emails}",
           emails: join_list(missing)
         )}

      :skip ->
        :ok
    end
  end

  # one or more addresses separated by commas, spaces or new lines, all in the domain
  defp parse_admin_emails(text, domain) do
    emails =
      text
      |> to_string()
      |> String.split(~r/[\s,;、]+/, trim: true)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    bad = Enum.reject(emails, &String.match?(&1, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/))

    outside =
      if is_binary(domain) and domain != "",
        do: Enum.reject(emails -- bad, &String.ends_with?(&1, "@" <> String.downcase(domain))),
        else: []

    cond do
      emails == [] ->
        {:error, gettext("Enter the administrators' email addresses.")}

      bad != [] ->
        {:error,
         gettext("Can't read these as email addresses: %{values}", values: join_list(bad))}

      outside != [] ->
        {:error,
         gettext("Addresses outside @%{domain} can't be used: %{emails}",
           domain: domain,
           emails: join_list(outside)
         )}

      true ->
        {:ok, emails}
    end
  end

  # --- Switching a feature on or off (F-206) ---------------------------------------------
  # {:ok, socket, label} or {:error, message, label}. Turning on checks the saved values.

  defp set_feature(feature, on?, socket) when is_map_key(@setting_toggles, feature) do
    {field, label} = @setting_toggles[feature]
    label = Gettext.gettext(AskDriveWeb.Gettext, label)

    case Settings.update_setting(socket.assigns.setting, %{field => on?}) do
      {:ok, updated} -> {:ok, refresh_setting(socket, updated), label}
      {:error, changeset} -> {:error, changeset_messages(changeset), label}
    end
  end

  defp set_feature("oauth_login", on?, socket) do
    label = gettext("Google login")

    if on? and not AskDrive.Drive.OAuth.client_configured?() do
      {:error, gettext("Save the OAuth client ID and secret first"), label}
    else
      case Settings.update_setting(socket.assigns.setting, %{oauth_login_enabled: on?}) do
        {:ok, updated} -> {:ok, refresh_setting(socket, updated), label}
        {:error, changeset} -> {:error, changeset_messages(changeset), label}
      end
    end
  end

  defp set_feature("ldap", on?, socket) do
    case Settings.update_ldap(socket.assigns.setting, %{"ldap_enabled" => to_string(on?)}) do
      {:ok, updated} ->
        {:ok, socket |> refresh_setting(updated) |> assign(:ldap_form, ldap_form(updated)),
         gettext("Sign-in with LDAP")}

      {:error, changeset} ->
        {:error, changeset_messages(changeset), gettext("Sign-in with LDAP")}
    end
  end

  defp set_feature("access_password", on?, socket) do
    label = gettext("Restrict access by password")

    result =
      if on?,
        do: AdminAccess.enable_access_password(socket.assigns.setting),
        else: AdminAccess.disable_access_password(socket.assigns.setting)

    case result do
      {:ok, updated} -> {:ok, socket |> assign(:setting, updated) |> load_dashboard_data(), label}
      {:error, :no_password} -> {:error, gettext("Save a password first"), label}
      {:error, reason} -> {:error, inspect(reason), label}
    end
  end

  defp set_feature("gateway", on?, socket) do
    label = gettext("API gateway check")
    current = AskDrive.Gateway.settings()
    problems = if on?, do: AskDrive.Gateway.enable_problems(current), else: []

    with [] <- problems,
         :ok <- if(on?, do: still_reachable(current, socket), else: :ok) do
      :ok = AskDrive.Gateway.set_enabled!(on?)
      {:ok, assign(socket, :gateway_settings, AskDrive.Gateway.settings()), label}
    else
      {:error, [message]} -> {:error, message, label}
      problems when is_list(problems) -> {:error, Enum.join(problems, "／"), label}
    end
  end

  defp set_feature("acme", on?, socket) do
    label = gettext("Let's Encrypt automatic renewal")

    case Settings.set_acme_enabled(socket.assigns.setting, on?) do
      {:ok, updated} ->
        {:ok, socket |> refresh_setting(updated) |> assign(:acme_form, acme_form(updated)), label}

      {:error, changeset} ->
        {:error, changeset_messages(changeset), label}
    end
  end

  defp set_feature(_feature, _on?, _socket),
    do: {:error, gettext("Unknown feature"), gettext("This feature")}

  defp refresh_setting(socket, updated),
    do:
      socket
      |> assign(:setting, updated)
      |> assign_settings_form(updated)

  # the Let's Encrypt form (F-1009); the API key is never echoed back
  defp acme_form(setting),
    do: to_form(AskDrive.Settings.Setting.acme_changeset(setting, %{}), as: :acme)

  # the LDAP form's fields as the saved settings have them
  defp ldap_form(setting) do
    %{
      "ldap_enabled" => to_string(setting.ldap_enabled == true),
      "ldap_host" => setting.ldap_host || "",
      "ldap_port" => if(setting.ldap_port, do: to_string(setting.ldap_port), else: ""),
      "ldap_base_dn" => setting.ldap_base_dn || "",
      "ldap_bind_dn" => setting.ldap_bind_dn || ""
    }
  end

  # switched on with blank fields: Google's server, LDAPS port and the domain's base DN
  # Google's defaults for what is left blank (F-1306)
  defp autofill_ldap(form, setting) do
    fill = fn form, key, value ->
      if String.trim(form[key] || "") == "" and value, do: Map.put(form, key, value), else: form
    end

    form
    |> fill.("ldap_host", AskDrive.Ldap.default_host())
    |> fill.("ldap_port", to_string(AskDrive.Ldap.default_port()))
    |> fill.("ldap_base_dn", AskDrive.Ldap.domain_base_dn(setting.allowed_domain))
  end

  # newly chosen PEM files, kept (with their names) until saved, so a test and then a save
  # don't need the files chosen twice
  defp take_ldap_uploads(socket) do
    pending =
      Enum.reduce(
        [cert: :ldap_cert, key: :ldap_key, ca: :ldap_ca],
        socket.assigns.ldap_pending,
        fn
          {kind, upload}, acc ->
            case consume_uploaded_entries(socket, upload, fn %{path: path}, entry ->
                   {:ok, {entry.client_name, File.read!(path)}}
                 end) do
              [file | _] -> Map.put(acc, kind, file)
              [] -> acc
            end
        end
      )

    assign(socket, :ldap_pending, pending)
  end

  # a list of addresses / values in a message ("、" in Japanese)
  defp join_list(items), do: Enum.join(items, gettext(", "))

  defp changeset_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Map.values()
    |> List.flatten()
    |> Enum.join("／")
  end

  defp eta_label(sec) when sec < 60, do: gettext("Less than 1 min")
  defp eta_label(sec) when sec < 3600, do: gettext("About %{min} min", min: div(sec + 59, 60))

  defp eta_label(sec),
    do:
      gettext("About %{hours} h %{min} min", hours: div(sec, 3600), min: div(rem(sec, 3600), 60))

  # Progress.overview plus, while generating, whether the pace reaches the cut-off time.
  # The overall percentage is by expected time, from earlier runs' phase times (F-354).
  defp progress_view(run) do
    now = DateTime.utc_now()

    # this run's own cut-off: in the nightly batch, its share of the night (F-355)
    deadline =
      run.generation_deadline || Scheduler.calculate_deadline(Settings.platform_setting!())

    opts =
      if run.status == "running",
        do: [history: Progress.phase_history(run.kind), deadline: deadline],
        else: []

    case Progress.overview(run, now, opts) do
      %{phase: "generate", eta_seconds: eta} = view
      when is_integer(eta) and run.status == "running" ->
        if DateTime.compare(DateTime.add(now, eta), deadline) == :gt,
          do: Map.put(view, :past_deadline, AskDrive.Clock.format(deadline, "%H:%M")),
          else: view

      view ->
        view
    end
  end

  defp format_seconds(sec) when sec < 60, do: gettext("%{sec}s", sec: sec)

  defp format_seconds(sec) when sec < 3600,
    do: gettext("%{min}m %{sec}s", min: div(sec, 60), sec: rem(sec, 60))

  defp format_seconds(sec),
    do: gettext("%{hours}h %{min}m", hours: div(sec, 3600), min: div(rem(sec, 3600), 60))

  # Installed / required Ollama models and download progress for the settings screen.
  defp assign_ollama_models(socket) do
    alias AskDrive.LLM.OllamaModels

    setting = socket.assigns[:setting] || Settings.get_setting!()

    # a desk's settings only, and only when that desk uses (or is switching to) Ollama:
    # otherwise Ollama isn't even asked (it may well not be running)
    required =
      if socket.assigns[:scope] == :platform, do: [], else: OllamaModels.required(setting)

    # the pulled models, for the desk's Ollama model pull-downs (F-838)
    uses_ollama? =
      required != [] or
        (socket.assigns[:scope] == :app and
           "ollama" in ((socket.assigns[:llm_view] || %{})[:in_use] || []))

    catalog = if uses_ollama?, do: OllamaModels.catalog(setting), else: {:ok, []}

    installed =
      case catalog do
        {:ok, models} -> {:ok, Enum.map(models, & &1.name)}
        error -> error
      end

    socket
    |> assign(:ollama_catalog, catalog)
    |> assign(:ollama_installed, installed)
    |> assign(:ollama_required, required)
    |> assign(:ollama_pulls, OllamaModels.pulls())
  end

  defp format_cert_time(nil), do: "—"

  defp format_cert_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> AskDrive.Clock.format(dt, "%Y-%m-%d %H:%M")
      _ -> iso
    end
  end

  defp upload_error_label(:too_large), do: gettext("The file is too large")

  defp upload_error_label(:not_accepted),
    do: gettext("Choose a PEM file (.pem / .crt / .cer / .key)")

  defp upload_error_label(:too_many_files), do: gettext("Choose only one file")
  defp upload_error_label(other), do: inspect(other)

  # The page that clicked "apply" is gone after the endpoint restart; a failure (rolled back
  # to the previous certificate) is kept here so the reconnected page can show it.
  defp record_ssl_result(:ok), do: :persistent_term.erase({__MODULE__, :ssl_result})

  defp record_ssl_result({:error, message}),
    do: :persistent_term.put({__MODULE__, :ssl_result}, "前回の証明書の適用に失敗しました: #{message}")

  # the client certificate this admin's browser presented, if any (spec 6.14)
  defp peer_cert(socket) do
    case get_connect_info(socket, :peer_data) do
      %{ssl_cert: der} when is_binary(der) -> der
      _ -> nil
    end
  end

  defp still_reachable(%{secret: nil}, _socket), do: :ok

  defp still_reachable(new, socket) do
    via_gateway? =
      is_binary(socket.assigns.gateway_header) and
        Plug.Crypto.secure_compare(socket.assigns.gateway_header, new.secret)

    if via_gateway? or
         AskDrive.Gateway.direct_allowed?(parse_ip(socket.assigns.peer_ip), new.direct_ranges),
       do: :ok,
       else:
         {:error,
          [
            gettext(
              "This connection (%{ip}) would be refused. Reopen the page through the gateway, do this from the server itself (localhost), or save this IP under \"IPs allowed direct access\"",
              ip: socket.assigns.peer_ip || gettext("unknown")
            )
          ]}
  end

  # the API gateway's secret header on this admin's connection, if any (F-1014)
  defp gateway_header(socket) do
    header = AskDrive.Gateway.header()

    case get_connect_info(socket, :x_headers) do
      headers when is_list(headers) ->
        Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == header, do: v end)

      _ ->
        nil
    end
  end

  # the TCP peer of this admin's connection (to tell whether it came through a proxy)
  defp peer_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: ip} -> ip |> :inet.ntoa() |> to_string()
      _ -> nil
    end
  end

  defp issued_panel(group, cert, password, token, again?) do
    %{
      group: group.name,
      name: AskDrive.ClientCerts.display_name(group.name, cert.label),
      expires: cert.not_after,
      password: password,
      token: token,
      again?: again?
    }
  end

  defp parse_ip(text) when is_binary(text) do
    case :inet.parse_address(String.to_charlist(text)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp parse_ip(_unknown), do: nil

  defp last_ssl_result, do: :persistent_term.get({__MODULE__, :ssl_result}, nil)

  # Per-app figures for the platform's 窓口 tab
  defp app_summaries do
    AskDrive.Apps.each(fn _app ->
      last = Scheduler.list_runs(1) |> List.first()

      %{
        docs: Repo.aggregate(Document, :count, :id) || 0,
        chunks: Repo.aggregate(Chunk, :count, :id) || 0,
        drive?: Accounts.drive_connected?(),
        auto?: Settings.get_setting!().auto_batch_enabled != false,
        last_run: last
      }
    end)
    |> Map.new(fn {app, summary} -> {app.slug, summary} end)
  end

  # File pickers styled as buttons: the browser's default "ファイルを選択" looked like plain
  # text on a white card, so it wasn't obvious it could be clicked.
  defp ssl_file_input_class do
    [
      "block w-full text-xs text-zinc-600 dark:text-zinc-300 cursor-pointer",
      "rounded-lg border border-dashed border-zinc-300 dark:border-zinc-700 p-1.5",
      "hover:border-indigo-400 dark:hover:border-indigo-500 transition",
      "file:mr-3 file:px-3 file:py-1.5 file:rounded-md file:border-0 file:cursor-pointer",
      "file:bg-indigo-600 file:text-white file:text-xs file:font-medium",
      "hover:file:bg-indigo-700"
    ]
  end

  defp create_app_done(socket, app) do
    create_app_result(socket, {:ok, app})
  end

  defp create_app_result(socket, result) do
    case result do
      {:ok, app} ->
        {:noreply,
         socket
         |> assign(:apps, AskDrive.Apps.list())
         |> assign(:show_new_app, false)
         |> assign(:last_created_app, app)
         |> assign(:app_form, blank_app_form())
         |> load_dashboard_data()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :app_form, to_form(Map.put(cs, :action, :insert), as: :app))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not create the desk: %{reason}", reason: inspect(reason))
         )}
    end
  end

  defp blank_app_form,
    do: to_form(AskDrive.Apps.App.changeset(%AskDrive.Apps.App{}, %{}), as: :app)

  defp slug_preview(form) do
    case form[:slug].value |> to_string() |> String.trim() |> String.downcase() do
      "" -> gettext("(URL name)")
      slug -> slug
    end
  end

  # no authorization started (no OAuth client yet): nothing to complete the pasted address with
  defp finish_drive_auth(%{assigns: %{drive_auth: nil}} = socket) do
    message =
      gettext(
        "Set up an OAuth client first, then authorize with \"Open Google's authorization screen\"."
      )

    {:noreply,
     socket |> assign(:drive_auth_result, {:error, message}) |> put_flash(:error, message)}
  end

  defp finish_drive_auth(socket) do
    alias AskDrive.Drive.OAuth
    %{state: state, verifier: verifier, redirect_uri: redirect_uri} = socket.assigns.drive_auth

    result =
      with {:ok, code} <- OAuth.code_from_paste(socket.assigns.drive_auth_code, state),
           # used once: Google's return to AskDrive can't finish it again (F-352)
           _ <- AskDrive.Drive.PendingAuth.take(state),
           {:ok, tokens} <- OAuth.exchange_manual_code(code, verifier, redirect_uri),
           :ok <- drive_account_allowed(tokens[:email]),
           {:ok, account} <- Accounts.save_tokens(tokens) do
        {:ok, account}
      end

    case result do
      {:ok, account} ->
        Logger.info("AdminLive: Drive sync account #{account.email} authorized by pasted code")

        {:noreply,
         socket
         |> assign(:drive_auth_code, "")
         |> assign(:drive_auth, nil)
         |> assign(
           :drive_auth_result,
           {:ok, gettext("Connected %{email}.", email: account.email)}
         )
         |> put_flash(
           :info,
           gettext(
             "Connected the Google Drive sync account (%{email}). Check it with \"Test sync\".",
             email: account.email
           )
         )
         |> load_dashboard_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:drive_auth_result, {:error, drive_auth_error(reason)})
         |> put_flash(:error, drive_auth_error(reason))}
    end
  end

  defp save_service_account_params(socket, params, folder) do
    json = String.trim(params["drive_service_account_json"] || "")

    # The key field always renders empty (it is a secret), so a blank submit means "keep the
    # stored key" — that lets the delegation user be changed without re-pasting the key.
    attrs =
      %{
        drive_auth_mode: "service_account",
        drive_impersonate_email: params["drive_impersonate_email"]
      }
      |> then(&if(json == "", do: &1, else: Map.put(&1, :drive_service_account_json, json)))
      |> Map.merge(Map.new(folder, fn {k, v} -> {String.to_existing_atom(k), v} end))

    # Delegation acts as a user of the organization's Workspace, so the address must be in
    # the domain set on the platform (spec 6.12)
    domain = Settings.platform_setting!().allowed_domain
    subject = String.trim(params["drive_impersonate_email"] || "")

    if domain not in [nil, ""] and subject != "" and
         not String.ends_with?(String.downcase(subject), "@" <> domain) do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("The access user must be an address in the organization's domain (@%{domain}).",
           domain: domain
         )
       )}
    else
      save_drive_settings(socket, attrs)
    end
  end

  defp save_drive_settings(socket, attrs) do
    case Settings.update_setting(socket.assigns.setting, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign_settings_form(updated)
         |> assign(:service_account_test, nil)
         |> assign_drive_mode()
         |> put_flash(:info, gettext("Google Drive sync settings saved."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(
           :error,
           gettext("Save failed: %{errors}", errors: changeset_messages(changeset))
         )}
    end
  end
end
