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

  alias AskDrive.Accounts.{AdminAccess, AdminElevationLog}
  alias AskDrive.Batch.{ItemLog, Progress, Scheduler}
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.Drive.{Client, ServiceAccount}
  alias AskDrive.LLM
  alias AskDrive.QA.QAPair
  alias AskDrive.{Accounts, Documents, HealthCheck, QA, Repo, Settings, Vector}
  alias AskDrive.Runtime.Mode

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Refresh status periodically
      :timer.send_interval(5000, self(), :tick)
      # Ollama model download progress (spec F-827)
      Phoenix.PubSub.subscribe(AskDrive.PubSub, AskDrive.LLM.OllamaModels.topic())
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
      |> assign(:peer_ip, peer_ip(socket))
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

    {:ok,
     socket
     |> assign(:current_tab, default_tab(scope))
     |> assign(:setting, setting)
     |> assign(:ldap_form, ldap_form(setting))
     |> assign(:form, form)
     |> assign(:trigger_batch_loading, false)
     |> assign(:connection_test, %{})
     |> assign(:service_account_test, nil)
     |> assign(:password_form, to_form(%{}, as: :admin_password))
     |> assign(:access_password_form, to_form(%{}, as: :access_password))
     |> assign(:resetting_app_slug, nil)
     |> load_dashboard_data()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tabs = Enum.map(tabs(socket.assigns.scope), &elem(&1, 0))
    tab = if params["tab"] in tabs, do: params["tab"], else: default_tab(socket.assigns.scope)
    {:noreply, assign(socket, :current_tab, tab)}
  end

  defp tabs(:platform),
    do: [
      {"apps", "窓口（アプリ）"},
      {"users", "ユーザー管理"},
      {"audit", "昇格ログ"},
      {"metrics", "API利用量・ログ"},
      {"settings", "全体設定"}
    ]

  defp tabs(:app),
    do: [
      {"overview", "概要・バッチ状況"},
      {"questions", "未回答・解消質問"},
      {"documents", "ドキュメント一覧"},
      {"metrics", "API利用量・ログ"},
      {"settings", "設定"}
    ]

  defp default_tab(scope), do: scope |> tabs() |> hd() |> elem(0)

  @impl true
  def handle_info({:ollama_pulls, pulls}, socket) do
    socket = assign(socket, :ollama_pulls, pulls)

    # a finished download changes what's installed
    socket =
      if Enum.any?(pulls, fn {_m, p} -> p.status in ["done", "failed"] end),
        do: assign_ollama_models(socket),
        else: socket

    {:noreply, socket}
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
          do: Ecto.Changeset.add_error(cs, :slug, "は既に使われています"),
          else: cs
      end)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :app_form, to_form(changeset, as: :app))}
  end

  def handle_event("create_app", %{"app" => params}, socket) do
    case AskDrive.Apps.create(params) do
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
        {:noreply, put_flash(socket, :error, "窓口を作成できませんでした: #{inspect(reason)}")}
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
         |> put_flash(:info, "窓口を更新しました。")
         |> load_dashboard_data()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "窓口名を入力してください。")}
    end
  end

  def handle_event("delete_app", %{"id" => id}, socket) do
    app = AskDrive.Apps.get!(String.to_integer(id))

    case AskDrive.Apps.delete(app) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:apps, AskDrive.Apps.list())
         |> put_flash(:info, "窓口「#{app.name}」を削除しました（データベースファイルは名前を変えて残しています）。")
         |> load_dashboard_data()}

      {:error, :primary} ->
        {:noreply, put_flash(socket, :error, "最初の窓口は削除できません。")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "削除できませんでした: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("ssl_upload_change", _params, socket), do: {:noreply, socket}

  # The LDAP form keeps what is being typed (a re-render must not reset it) and fills in the
  # Google defaults when sign-in is switched on (spec F-1306).
  def handle_event("ldap_change", %{"ldap" => params}, socket) do
    {:noreply, assign(socket, :ldap_form, autofill_ldap(params, socket.assigns.setting))}
  end

  def handle_event("ldap_change", _params, socket), do: {:noreply, socket}

  # "保存" and "接続テスト" submit the same form (the button pressed arrives as "op"):
  # the test runs on the form's contents, saved or not, including newly chosen files.
  def handle_event("save_ldap", params, socket) do
    socket = take_ldap_uploads(socket)
    form = autofill_ldap(Map.get(params, "ldap", %{}), socket.assigns.setting)
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
           |> assign(:form, to_form(Settings.change_setting(updated)))
           |> assign(:ldap_form, ldap_form(updated))
           |> assign(:ldap_pending, %{})
           |> put_flash(:info, "LDAP ログインの設定を保存しました。")}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, "保存できませんでした: " <> changeset_messages(changeset))}
      end
    end
  end

  # Required login (spec F-1308). Switching it on from the guest (POC) session would leave
  # nobody able to administer unless someone can sign in and elevate, so it needs a way to
  # sign in (LDAP or Google), the administrator password, and an administrator account.
  def handle_event("enable_auth", %{"admin_email" => text}, socket) do
    setting = Settings.platform_setting!()
    parsed = parse_admin_emails(text, setting.allowed_domain)

    problem =
      cond do
        elem(AskDriveWeb.UserAuth.auth_mode(), 1) == :env ->
          "環境変数 ASK_DRIVE_DISABLE_AUTH で固定されています。.env.prod からこの行を削除して再起動してください。"

        not (AskDrive.Ldap.enabled?(setting) or AskDrive.Drive.OAuth.login_enabled?()) ->
          "ログインの方法がありません。先に「Google Secure LDAP でのログイン」または Google ログイン（OAuth）を設定してください。"

        not AdminAccess.password_set?(setting) ->
          "管理者パスワードが未設定です。先に設定してください。"

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
      {:ok, _} = Settings.set_auth_required(true)

      Logger.info(
        "AdminLive: login required switched on (administrators: #{Enum.join(emails, ", ")})"
      )

      {:noreply,
       socket
       |> put_flash(
         :info,
         "ログイン認証を有効にしました。#{Enum.join(emails, "、")} のいずれかでログインし、管理者パスワードで昇格してください。"
       )
       |> redirect(to: ~p"/login")}
    end
  end

  # Administrators by e-mail, including people who have never signed in (they appear in the
  # list once registered, and elevate after their first sign-in)
  def handle_event("grant_admin_emails", %{"emails" => text}, socket) do
    case parse_admin_emails(text, Settings.platform_setting!().allowed_domain) do
      {:ok, emails} ->
        Enum.each(emails, fn email -> {:ok, _} = Accounts.grant_admin(email) end)
        Logger.info("AdminLive: administrators added: #{Enum.join(emails, ", ")}")

        {:noreply,
         socket
         |> put_flash(:info, "#{Enum.join(emails, "、")} を昇格可にしました。")
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
         "環境変数 ASK_DRIVE_DISABLE_AUTH で固定されています。.env.prod からこの行を削除して再起動してください。"
       )}
    else
      {:ok, _} = Settings.set_auth_required(false)
      Logger.warning("AdminLive: login required switched off (guest mode)")

      {:noreply,
       socket
       |> put_flash(:info, "ログイン認証を無効にしました（誰でもゲストとして管理者操作ができます）。")
       |> load_dashboard_data()}
    end
  end

  def handle_event("unlock_login", %{"id" => id}, socket) do
    socket =
      case AskDrive.Accounts.LoginThrottle.unlock(String.to_integer(id)) do
        {:ok, lock} ->
          Logger.info("AdminLive: login lock lifted (#{lock.scope} #{lock.email || lock.ip})")
          put_flash(socket, :info, "ロックを解除しました。")

        {:error, :not_found} ->
          put_flash(socket, :error, "このロックはすでに解除されています。")
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
          {:error, ["証明書と秘密鍵の両方を選択してください"]}

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
         |> put_flash(:info, "証明書を適用しています。数秒後にページが自動で再接続します（再接続しない場合は再読み込みしてください）。")}

      _ ->
        {:noreply, put_flash(socket, :error, "先に「検証する」で証明書を検証してください。")}
    end
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
             "ポートを変更して再起動しています。数秒後に https://<ホスト>:#{new.https_port}/admin?tab=settings を開き直してください（起動できなければ元の設定に戻ります）。"
           )}
        else
          {:ok, _, :applied} = AskDrive.Network.apply_settings(new)
          {:noreply, put_flash(socket, :info, "リバースプロキシの設定を保存しました（すぐに反映されます）。")}
        end

      {:error, errors} ->
        {:noreply, put_flash(socket, :error, "保存できませんでした: " <> Enum.join(errors, "／"))}
    end
  end

  def handle_event("reset_self_signed", _params, socket) do
    spawn(fn ->
      Process.sleep(500)
      record_ssl_result(AskDrive.SSL.reset_to_self_signed())
    end)

    {:noreply, put_flash(socket, :info, "自己署名証明書を作り直して適用しています。数秒後にページが自動で再接続します。")}
  end

  def handle_event("cancel_ssl_upload", %{"ref" => ref, "upload" => upload}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}
  end

  @impl true
  def handle_event("pull_model", %{"model" => model}, socket) do
    case String.trim(model) do
      "" ->
        {:noreply, socket}

      name ->
        AskDrive.LLM.OllamaModels.pull_async(name)
        {:noreply, put_flash(socket, :info, "#{name} の取得を開始しました（数分かかることがあります）。")}
    end
  end

  @impl true
  def handle_event("select_run", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_run_id, String.to_integer(id)) |> load_dashboard_data()}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: "#{socket.assigns.base_path}/admin?tab=#{tab}")}
  end

  @impl true
  def handle_event("retry_given_up", _params, socket) do
    count = Scheduler.retry_given_up_chunks()

    {:noreply,
     socket
     |> put_flash(:info, "#{count} 件のチャンクを QA 生成の対象に戻しました。次のバッチで再び生成します。")
     |> load_dashboard_data()}
  end

  def handle_event("stop_batch", _params, socket) do
    socket =
      case Scheduler.request_stop() do
        :ok ->
          Logger.info("AdminLive: stop requested for the running batch")
          put_flash(socket, :info, "バッチの停止を要求しました。処理中の項目が終わり次第止まります。")

        {:error, :not_running} ->
          put_flash(socket, :error, "実行中のバッチはありません。")
      end

    {:noreply, load_dashboard_data(socket)}
  end

  def handle_event("trigger_batch", params, socket) do
    ingest_only? = params["kind"] == "ingest_only"

    if Scheduler.running?() do
      {:noreply, put_flash(socket, :error, "バッチが実行中です。終了してから実行してください。")}
    else
      Logger.info("AdminLive: Triggering manual batch run (ingest_only: #{ingest_only?})...")
      # bind: run the batch against this app's database (spec 6.11)
      Task.start(AskDrive.Apps.bind(fn -> Scheduler.run_batch(ingest_only: ingest_only?) end))

      message =
        if ingest_only?,
          do: "取り込みのみのバッチを開始しました（QA 生成は行いません）。",
          else: "バッチ（QA 生成あり）の実行を開始しました。"

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> load_dashboard_data()}
    end
  end

  @impl true
  def handle_event("save_settings", %{"setting" => setting_params}, socket) do
    # `vec0` fixes the vector width at CREATE time, so a new embedding model or dimension
    # means dropping and rebuilding the index before anything can be re-embedded (F-809).
    reindex? = Settings.reindex_required?(socket.assigns.setting, setting_params)

    case Settings.update_setting(socket.assigns.setting, setting_params) do
      {:ok, updated} ->
        # A model named in the settings that Ollama doesn't have yet starts downloading now
        AskDrive.LLM.OllamaModels.ensure_required(updated)

        message =
          if reindex? do
            case Vector.rebuild_index(updated.embedding_dim) do
              {:ok, _dim} ->
                "設定を保存し、ベクトルインデックスを再構築しました。次回の夜間バッチで全チャンクを再ベクトル化します。"

              {:error, reason} ->
                Logger.error("Vector index rebuild failed: #{inspect(reason)}")
                "設定は保存しましたが、ベクトルインデックスの再構築に失敗しました。ログを確認してください。"
            end
          else
            "設定を保存しました。"
          end

        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign(:form, to_form(Settings.change_setting(updated)))
         |> put_flash(:info, message)
         |> load_dashboard_data()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(:error, "設定の保存に失敗しました。入力内容を確認してください。")}
    end
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
         |> assign(:form, to_form(Settings.change_setting(updated)))
         |> assign(:service_account_test, nil)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Drive 認証方式を切り替えられませんでした。")}
    end
  end

  @impl true
  def handle_event("save_service_account", %{"setting" => params}, socket) do
    json = String.trim(params["drive_service_account_json"] || "")

    # The key field always renders empty (it is a secret), so a blank submit means "keep the
    # stored key" — that lets the delegation user be changed without re-pasting the key.
    attrs =
      %{
        drive_auth_mode: "service_account",
        drive_impersonate_email: params["drive_impersonate_email"]
      }
      |> then(&if(json == "", do: &1, else: Map.put(&1, :drive_service_account_json, json)))

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
         "なりすますユーザーは組織のドメイン（@#{domain}）のアドレスを指定してください。"
       )}
    else
      save_service_account(socket, attrs)
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
          {:error, "先に JSON キーを保存してください。"}
      end

    {:noreply, assign(socket, :service_account_test, result)}
  end

  @impl true
  def handle_event("disconnect_service_account", _params, socket) do
    Accounts.disconnect_service_account()

    {:noreply,
     socket
     |> assign(:setting, Settings.get_setting!())
     |> assign(:service_account_test, nil)
     |> put_flash(:info, "サービスアカウントの認証情報を削除しました。")
     |> load_dashboard_data()}
  end

  @impl true
  def handle_event("set_admin_eligible", %{"id" => id, "eligible" => eligible}, socket) do
    socket.assigns.current_user
    |> Accounts.set_admin_eligible(Accounts.get_user(id), eligible == "true")
    |> handle_user_change(socket)
  end

  @impl true
  def handle_event("toggle_user_app_admin", %{"user_id" => user_id, "app_slug" => slug}, socket) do
    user = Accounts.get_user(user_id)

    if user do
      current_slugs = Accounts.list_user_app_slugs(user)

      new_slugs =
        if slug in current_slugs do
          current_slugs -- [slug]
        else
          [slug | current_slugs]
        end

      :ok = Accounts.set_user_apps(user, new_slugs)

      {:noreply,
       socket
       |> put_flash(:info, "#{user.email} の窓口管理者権限を更新しました。")
       |> load_dashboard_data()}
    else
      {:noreply, put_flash(socket, :error, "ユーザーが見つかりません。")}
    end
  end

  @impl true
  def handle_event("change_admin_password", %{"admin_password" => params}, socket) do
    %{"current" => current, "new" => new_password, "confirmation" => confirmation} =
      Map.merge(%{"current" => "", "new" => "", "confirmation" => ""}, params)

    context = %{ip_address: nil, user_agent: nil}

    result =
      if new_password != confirmation do
        {:error, :mismatch}
      else
        AdminAccess.change_password(
          socket.assigns.current_user,
          current,
          new_password,
          context,
          socket.assigns.setting
        )
      end

    case result do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> put_flash(:info, "管理者パスワードを変更しました。")
         |> load_dashboard_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, password_error_message(reason))}
    end
  end

  @impl true
  def handle_event("toggle_reset_app_password", %{"app_slug" => app_slug}, socket) do
    next_slug =
      if is_binary(app_slug) and app_slug != "" and socket.assigns.resetting_app_slug != app_slug,
        do: app_slug,
        else: nil

    {:noreply, assign(socket, :resetting_app_slug, next_slug)}
  end

  @impl true
  def handle_event(
        "reset_app_admin_password",
        %{"app_slug" => app_slug, "new_password" => new_password, "confirmation" => confirmation},
        socket
      ) do
    app = AskDrive.Apps.get_by_slug!(app_slug)
    context = %{ip_address: nil, user_agent: nil}

    result =
      if new_password != confirmation do
        {:error, :mismatch}
      else
        AdminAccess.reset_app_admin_password(
          socket.assigns.current_user,
          app,
          new_password,
          context
        )
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:resetting_app_slug, nil)
         |> put_flash(:info, "窓口「#{app.name}」の管理者パスワードを再設定しました。")
         |> load_dashboard_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, password_error_message(reason))}
    end
  end

  @impl true
  def handle_event("save_access_password", %{"access_password" => params}, socket) do
    enabled = params["enabled"] in ["true", "1", true]
    new_password = params["password"] || ""
    confirmation = params["confirmation"] || ""

    result =
      if enabled do
        if new_password != confirmation do
          {:error, :mismatch}
        else
          AdminAccess.set_access_password(socket.assigns.setting, new_password)
        end
      else
        AdminAccess.disable_access_password(socket.assigns.setting)
      end

    case result do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> put_flash(
           :info,
           if(enabled,
             do: "窓口アクセスパスワード（合言葉）を設定しました。",
             else: "窓口アクセスパスワード（合言葉）を無効化しました。"
           )
         )
         |> load_dashboard_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, password_error_message(reason))}
    end
  end

  @impl true
  def handle_event("disable_access_password", _params, socket) do
    case AdminAccess.disable_access_password(socket.assigns.setting) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> put_flash(:info, "窓口アクセスパスワード（合言葉）を無効化しました。")
         |> load_dashboard_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "無効化できませんでした: #{inspect(reason)}")}
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

  defp password_error_message(:mismatch), do: "新しいパスワードが一致しません。"
  defp password_error_message(:invalid_password), do: "現在のパスワードが違います。"

  defp password_error_message(:too_short),
    do: "パスワードは #{AdminAccess.min_password_length()} 文字以上にしてください。"

  defp password_error_message(:surrounding_whitespace), do: "パスワードの前後に空白を含めないでください。"
  defp password_error_message(:not_authorized), do: "この操作を行う権限がありません。"
  defp password_error_message(_), do: "パスワードの変更・設定に失敗しました。"

  defp handle_user_change({:ok, user}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "#{user.email} を更新しました。")
     |> load_dashboard_data()}
  end

  defp handle_user_change({:error, :cannot_modify_self}, socket) do
    {:noreply, put_flash(socket, :error, "自分自身の権限や状態は変更できません。")}
  end

  defp handle_user_change({:error, :last_admin}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "昇格可能なアカウントを 0 件にはできません。先に別のアカウントに昇格を許可してください。"
     )}
  end

  defp handle_user_change({:error, _changeset}, socket) do
    {:noreply, put_flash(socket, :error, "ユーザーの更新に失敗しました。")}
  end

  # `<.input type="select">` wants {label, value} pairs; the identifiers themselves are too
  # terse to show to an operator.
  # Secrets are never echoed back into the form; the admin only needs to know whether one
  # is stored (N-610).
  defp secret_state(value) when is_binary(value) and value != "", do: "設定済み"
  defp secret_state(_), do: "未設定"

  defp provider_options(providers) do
    Enum.map(providers, fn provider -> {LLM.label(provider), provider} end)
  end

  defp load_dashboard_data(socket) do
    # 1. Batch history (spec F-338): recent runs, the one being inspected (latest unless the
    #    admin picked another row), and what the night-window trigger is doing.
    runs = Scheduler.list_runs(20)
    selected_id = socket.assigns[:selected_run_id]
    latest_run = Enum.find(runs, &(&1.id == selected_id)) || List.first(runs)
    item_logs = if latest_run, do: ItemLog.list_for_run(latest_run.id), else: []
    run_summaries = runs |> Enum.map(& &1.id) |> ItemLog.summaries()
    auto_status = Scheduler.auto_status()
    # progress of the run in progress (spec F-340); the dashboard ticks every 5 s
    running_run = Enum.find(runs, &(&1.status == "running"))

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
    |> assign(:admin_password_set?, AdminAccess.password_set?(setting))
    |> assign(:generation_provider, LLM.generation_provider(setting))
    |> assign(:embedding_provider, LLM.embedding_provider(setting))
    |> assign(:latest_run, latest_run)
    |> assign(:runs, runs)
    |> assign(:run_summaries, run_summaries)
    |> assign(:auto_status, auto_status)
    |> assign(:running_run, running_run)
    |> assign(:remaining, Scheduler.remaining())
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
      wide
    >
      <div class="space-y-6 pb-12">
        <%!-- Header Bar --%>
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-4 border-b border-zinc-200 dark:border-zinc-800">
          <div>
            <div class="flex items-center gap-2">
              <h1 class="font-bold text-2xl text-zinc-900 dark:text-zinc-100">
                {if @scope == :app, do: "管理: AskDrive for #{@app.name}", else: "全体管理"}
              </h1>
              <span
                id="app-version"
                title="稼働中の AskDrive のバージョン"
                class="text-[11px] font-mono px-2 py-0.5 rounded-full bg-zinc-100 dark:bg-zinc-800 text-zinc-500"
              >
                v{AskDrive.version()}
              </span>
            </div>
            <p class="text-xs text-zinc-500 mt-1">
              {if @scope == :app,
                do: "この窓口の夜間バッチ、ドキュメント、未回答質問、Google Drive と AI の設定を管理します。",
                else: "窓口（アプリ）の追加・管理、ユーザー、HTTPS、ローカルモデル、夜間バッチの時間帯など、AskDrive 全体の設定を管理します。"}
            </p>
          </div>

          <%!-- While this app's batch runs, the trigger buttons give way to stopping it (F-341) --%>
          <div :if={@scope == :app && @running_run} class="flex flex-wrap items-center gap-2">
            <%= if @running_run.stop_requested_at do %>
              <span
                id="stop-requested"
                class="text-xs px-3.5 py-2 rounded-lg bg-amber-50 dark:bg-amber-950/40 border border-amber-200 dark:border-amber-900 text-amber-800 dark:text-amber-200 flex items-center gap-1.5"
              >
                <.icon name="hero-clock" class="w-4 h-4" /> 停止を要求しました。処理中の項目が終わり次第止まります
              </span>
            <% else %>
              <button
                id="stop-batch-btn"
                phx-click="stop_batch"
                data-confirm="実行中のバッチを停止しますか？処理中のファイル（またはチャンク）が終わった時点で止まります。ここまでの取り込み・生成結果は残り、残りは次回のバッチで続きから処理します。"
                class="text-xs px-3.5 py-2 rounded-lg bg-red-600 hover:bg-red-700 text-white font-medium shadow-sm flex items-center gap-1.5 transition"
              >
                <.icon name="hero-stop" class="w-4 h-4" /> バッチを停止
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
                  do: "現在は営業時間相です。QA 生成ありのバッチは生成モデルを長時間占有し、その間チャットは原文検索のみ（キーワード中心）になります。続きから再実行しますか？",
                  else: "続きから再実行しますか？"
                )
              }
              title="前回のバッチが最後まで終わっていません。残りだけを処理します（済んだ部分はやり直しません）。"
              class="text-xs px-3.5 py-2 rounded-lg bg-amber-500 hover:bg-amber-600 text-white font-medium shadow-sm flex items-center gap-1.5 transition"
            >
              <.icon name="hero-arrow-path" class="w-4 h-4" /> 続きから再実行（残り {@remaining.chunks} チャンク）
            </button>
            <%!-- Ingest only (spec 6.3.8 F-331): sync + indexing, no QA generation, so the
                  local model stays free for chat. The safe default for daytime runs. --%>
            <button
              id="trigger-ingest-btn"
              phx-click="trigger_batch"
              phx-value-kind="ingest_only"
              title="Drive の同期と取り込み（本文抽出・埋め込み）だけを行います。QA 生成は行わないため、実行中もチャットは通常どおり使えます。"
              class="text-xs px-3.5 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium shadow-sm flex items-center gap-1.5 transition"
            >
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> 取り込みのみ実行
            </button>
            <button
              id="trigger-batch-btn"
              phx-click="trigger_batch"
              phx-value-kind="full"
              data-confirm={
                if(@current_mode == :daytime,
                  do:
                    "現在は営業時間相です。QA 生成ありのバッチは生成モデルを長時間占有し、その間チャットは原文検索のみ（キーワード中心）になります。通常は「取り込みのみ実行」で十分です。実行しますか？",
                  else: "バッチ（QA 生成あり）を手動実行しますか？"
                )
              }
              class="text-xs px-3.5 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium flex items-center gap-1.5 transition"
            >
              <.icon name="hero-play" class="w-4 h-4" /> フル実行（QA 生成あり）
            </button>
          </div>
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

            <%!-- Nightly trigger status and batch history (spec F-338) --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-clock" class="w-5 h-5 text-indigo-600" /> 夜間バッチの自動実行と履歴
                </h2>
                <span class="text-xs text-zinc-500">
                  夜間枠: 毎日 {pad2(elem(@auto_status.window, 0))}:00〜翌 {pad2(
                    elem(@auto_status.window, 1)
                  )}:00・打ち切り {pad2(@auto_status.deadline_hour)}:00（この PC のローカル時刻）
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
                  end
                ]}
              >
                <%= case @auto_status.state do %>
                  <% :running -> %>
                    バッチを実行中です。<span :if={@running_progress}>
                      全体の目安 {@running_progress.overall}% ・ ステップ {@running_progress.step}/{@running_progress.steps}「{@running_progress.label}」{if @running_progress.total >
                                                                                                                                                   0,
                                                                                                                                                 do:
                                                                                                                                                   " #{@running_progress.done} / #{@running_progress.total}"}
                    </span>
                  <% :done -> %>
                    {Calendar.strftime(@auto_status.window_start, "%-m/%-d")} の夜間枠は実行済みです（#{@auto_status.run.id}・{trigger_label(
                      @auto_status.run.trigger
                    )}・{AskDrive.Clock.format(@auto_status.run.started_at, "%H:%M")} 開始・{status_label(
                      @auto_status.run.status
                    )}）。次回の自動実行: {Calendar.strftime(@auto_status.next_start, "%-m/%-d %H:%M")}
                  <% :due -> %>
                    夜間枠内で、この枠の自動実行はまだありません。1 分以内に自動で開始します。
                  <% :missed -> %>
                    {Calendar.strftime(@auto_status.window_start, "%-m/%-d")} の夜間枠では、自動実行の記録がありません（再起動で中断されたものは除く。手動実行は自動実行の代わりになりません）。次回の自動実行: {Calendar.strftime(
                      @auto_status.next_start,
                      "%-m/%-d %H:%M"
                    )}
                <% end %>
              </div>

              <%= if @runs == [] do %>
                <p class="text-xs text-zinc-500">バッチの実行履歴はまだありません。</p>
              <% else %>
                <div class="overflow-x-auto">
                  <table
                    id="batch-history"
                    class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                  >
                    <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                      <tr>
                        <th class="py-2 px-2">#</th>
                        <th class="py-2 px-2">開始</th>
                        <th class="py-2 px-2 text-right">所要時間</th>
                        <th class="py-2 px-2">起動</th>
                        <th class="py-2 px-2">種別</th>
                        <th class="py-2 px-2">状態</th>
                        <th class="py-2 px-2 text-right">取り込み（文書 / チャンク）</th>
                        <th class="py-2 px-2 text-right">失敗</th>
                        <th class="py-2 px-2 text-right">生成QA</th>
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
                          {if run.kind == "ingest_only", do: "取り込みのみ", else: "フル"}
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
                  行をクリックすると、下の「バッチ実行状況」にそのバッチの詳細（フェーズ別内訳・ファイル別ログ）を表示します。
                </p>
              <% end %>
            </div>

            <%!-- Latest Batch Run Card --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex items-center justify-between">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" /> バッチ実行状況
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
                    取り込みのみ
                  </span>
                </div>
              </div>

              <%= if @latest_run do %>
                <div class="grid grid-cols-2 sm:grid-cols-5 gap-4 text-xs text-zinc-600 dark:text-zinc-400">
                  <div>
                    <span class="text-zinc-400 block">開始日時</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {AskDrive.Clock.format(@latest_run.started_at, "%Y-%m-%d %H:%M:%S")}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">終了日時</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {if @latest_run.finished_at,
                        do: AskDrive.Clock.format(@latest_run.finished_at, "%Y-%m-%d %H:%M:%S"),
                        else: "実行中..."}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">取り込み（成功文書 / チャンク）</span>
                    <span class="font-mono text-zinc-800 dark:text-zinc-200">
                      {count_logs(@item_logs, "embed_chunks", "indexed")} 件 / {sum_chunks(@item_logs)} 件
                      <span
                        :if={count_logs(@item_logs, "failed") > 0}
                        class="text-red-600 dark:text-red-400"
                      >
                        （失敗 {count_logs(@item_logs, "failed")} 件）
                      </span>
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">QA 生成（対象チャンク / 生成QA）</span>
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

                <%!-- Why a run failed (batch_runs.error): the message and where it happened --%>
                <div
                  :if={@latest_run.status == "failed" && @latest_run.error}
                  id="batch-error"
                  class="p-3 rounded-lg bg-red-50 dark:bg-red-950/40 border border-red-200 dark:border-red-900 space-y-1"
                >
                  <p class="text-xs font-semibold text-red-800 dark:text-red-200">
                    失敗の原因（エラー内容）
                  </p>
                  <pre class="text-[11px] leading-relaxed text-red-900 dark:text-red-100 whitespace-pre-wrap break-all max-h-60 overflow-y-auto">{@latest_run.error}</pre>
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
                  <p class="font-semibold text-indigo-900 dark:text-indigo-200">続きから再実行</p>
                  <p class="text-zinc-700 dark:text-zinc-300">
                    残り: 取り込み待ち {@remaining.documents} 文書・QA 未生成 {@remaining.chunks} チャンク・質問の埋め込み待ち {@remaining.questions} 件
                    <span :if={@remaining.given_up > 0} class="text-amber-700 dark:text-amber-300">
                      （3 回失敗して除外中 {@remaining.given_up} チャンク）
                    </span>
                  </p>
                  <p class="text-zinc-500">
                    取り込み済みの文書と、QA を生成済みのチャンクは再実行しません。前回失敗したチャンクは後回しにします。
                  </p>
                  <button
                    id="resume-batch-btn"
                    phx-click="trigger_batch"
                    phx-value-kind="full"
                    data-confirm={
                      if(@current_mode == :daytime,
                        do:
                          "現在は営業時間相です。QA 生成ありのバッチは生成モデルを長時間占有し、その間チャットは原文検索のみ（キーワード中心）になります。続きから再実行しますか？",
                        else: "続きから再実行しますか？"
                      )
                    }
                    class="px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium shadow-sm inline-flex items-center gap-1.5 transition"
                  >
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> 続きから再実行
                  </button>
                </div>

                <%!-- Progress of the run (spec F-340): overall, the current step, and the item --%>
                <div
                  :if={
                    @selected_progress &&
                      @latest_run.status in ["running", "aborted", "failed", "stopped"]
                  }
                  id="batch-progress"
                  class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3"
                >
                  <h3 class="text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                    {if @latest_run.status == "running", do: "進捗", else: "停止した位置"}
                  </h3>
                  <div>
                    <div class="flex items-baseline justify-between text-xs text-zinc-600 dark:text-zinc-400">
                      <span>全体の目安</span>
                      <span class="font-mono text-base font-semibold text-zinc-900 dark:text-zinc-100">
                        {@selected_progress.overall}%
                      </span>
                    </div>
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
                        ステップ {@selected_progress.step}/{@selected_progress.steps}: {@selected_progress.label}
                      </span>
                      <span
                        :if={@selected_progress.total > 0}
                        class="font-mono text-zinc-600 dark:text-zinc-400"
                      >
                        {@selected_progress.done} / {@selected_progress.total} 件（{@selected_progress.percent}%）
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
                      {if @latest_run.status == "running", do: "処理中", else: "最後に処理していたもの"}: {@selected_progress.item}
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
                      このステップの経過 {format_seconds(@selected_progress.elapsed_seconds)}<span :if={
                        @selected_progress.eta_seconds
                      }>・残り {eta_label(@selected_progress.eta_seconds)}（ここまでのペースから推定）</span>
                    </p>
                    <p
                      :if={@selected_progress[:past_deadline]}
                      class="text-amber-700 dark:text-amber-300"
                    >
                      このペースでは打ち切り時刻（{@selected_progress.past_deadline}）までに全件は終わらない見込みです。残りは次回のバッチで続きから生成します。
                    </p>
                  </div>
                  <p class="text-[11px] text-zinc-400">
                    全体の % はステップごとの重み（取り込みと想定QAの生成が大半）による目安です。この画面は 5 秒ごとに更新されます。
                  </p>
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
                          {Progress.label(stat.phase_name)}
                        </span>
                        <div class="text-right text-zinc-500">
                          <span>{stat.duration_seconds}秒</span>
                          <span class="text-[10px] ml-1 text-zinc-400">({stat.items_count}件)</span>
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
                      QA を生成できなかったチャンク（3 回失敗・{@remaining.given_up} 件）
                    </h3>
                    <button
                      id="retry-given-up-btn"
                      phx-click="retry_given_up"
                      class="text-xs px-3 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium inline-flex items-center gap-1.5 transition"
                    >
                      <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> 生成の対象に戻す
                    </button>
                  </div>
                  <p class="text-[11px] text-zinc-400">
                    バッチはこれらを飛ばします（毎晩同じチャンクで時間を使わないため）。モデルを変えたときや、原因を直したあとに対象へ戻してください。文書を更新すると、変わったチャンクは自動で対象に戻ります。
                  </p>
                  <div class="overflow-x-auto max-h-60 overflow-y-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                        <tr :for={chunk <- @given_up_chunks}>
                          <td class="py-1.5 px-2 break-all">
                            {(chunk.document && (chunk.document.path || chunk.document.name)) || "—"}（チャンク {chunk.position +
                              1}）
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
                    ファイル別ログ（{length(@item_logs)} 件・失敗を先頭に表示）
                  </h3>
                  <%= if @item_logs == [] do %>
                    <p class="text-xs text-zinc-500">
                      このバッチのファイル別ログはありません（v0.0.27 より前に実行したバッチには記録されていません）。
                    </p>
                  <% else %>
                    <div class="overflow-x-auto max-h-[28rem] overflow-y-auto">
                      <table
                        id="batch-item-logs"
                        class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                      >
                        <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800 sticky top-0 bg-white dark:bg-zinc-900">
                          <tr>
                            <th class="py-2 px-2">フェーズ</th>
                            <th class="py-2 px-2">結果</th>
                            <th class="py-2 px-2">ファイル</th>
                            <th class="py-2 px-2 text-right">チャンク</th>
                            <th class="py-2 px-2 text-right">時間</th>
                            <th class="py-2 px-2">詳細</th>
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
                <p class="text-xs text-zinc-500">夜間バッチの実行履歴はまだありません。</p>
              <% end %>
            </div>

            <%!-- System & Model Health --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-server" class="w-5 h-5 text-indigo-600" /> システム・推論基盤ステータス
              </h2>
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-4 text-xs">
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
                  <span class="text-zinc-400 block">
                    回答生成 ({LLM.label(@generation_provider)})
                  </span>
                  <span class="font-semibold text-emerald-600 mt-1 block">
                    <%= case @health.llm_generation do %>
                      <% {:ok, info} -> %>
                        接続中 ({info})
                      <% {:error, err} -> %>
                        <span class="text-red-600">未接続: {err}</span>
                    <% end %>
                  </span>
                  <span class="text-[10px] text-zinc-400 mt-0.5 block">
                    {LLM.generation_model(@setting)}{if LLM.cloud_mode?(@setting),
                      do: "（クラウド）"}
                  </span>
                </div>

                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800">
                  <span class="text-zinc-400 block">
                    埋め込み ({LLM.label(@embedding_provider)})
                  </span>
                  <span class="font-semibold text-emerald-600 mt-1 block">
                    <%= case @health.llm_embedding do %>
                      <% {:ok, info} -> %>
                        接続中 ({info})
                      <% {:error, err} -> %>
                        <span class="text-red-600">未接続: {err}</span>
                    <% end %>
                  </span>
                  <span class="text-[10px] text-zinc-400 mt-0.5 block">
                    {@setting.embed_model} / {@setting.embedding_dim} 次元
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
                          到達: Tier {q.tier_reached} ・ 質問日時: {AskDrive.Clock.format(
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
                          解消: {AskDrive.Clock.format(q.resolved_at, "%Y-%m-%d %H:%M")}
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
                      <th class="py-3 px-2 text-right">トークン効率</th>
                      <th class="py-3 px-2">最終同期</th>
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
                                String.starts_with?(eff.score_rating, "優良") ->
                                  "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

                                String.starts_with?(eff.score_rating, "良好") ->
                                  "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300"

                                String.starts_with?(eff.score_rating, "普通") ->
                                  "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

                                String.starts_with?(eff.score_rating, "要改善") ->
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

        <%!-- Platform: apps (spec 6.11) --%>
        <%= if @current_tab == "apps" do %>
          <div class="space-y-6">
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 flex-1">
                  <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                    <.icon name="hero-squares-2x2" class="w-5 h-5 text-indigo-600" /> 窓口（アプリ）
                  </h2>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    窓口ごとに Google Drive のフォルダ、Gemini などの API キー（費用負担を分けられます）、検索インデックス、QA、質問ログ、夜間バッチの履歴が分かれます。データは窓口ごとに別のデータベースに保存され、混ざりません。
                  </p>
                </div>
                <button
                  :if={not @show_new_app}
                  type="button"
                  id="show-new-app-btn"
                  phx-click="toggle_new_app"
                  class="shrink-0 inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium shadow-sm transition"
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> 窓口を追加
                </button>
              </div>

              <%!-- New app, right above the list (spec 6.11): validated as you type, with the
                    URL the app will get. --%>
              <div
                :if={@show_new_app}
                id="new-app-panel"
                class="p-4 rounded-xl border-2 border-indigo-200 dark:border-indigo-900 bg-indigo-50/40 dark:bg-indigo-950/20 space-y-3"
              >
                <h3 class="font-semibold text-sm text-zinc-900 dark:text-zinc-100">新しい窓口</h3>
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
                    label="窓口名（例: HR）"
                    phx-debounce="300"
                  />
                  <.input
                    field={@app_form[:slug]}
                    type="text"
                    label="URL 名（英小文字・数字・ハイフン）"
                    placeholder="hr"
                    phx-debounce="300"
                  />
                  <.input
                    field={@app_form[:description]}
                    type="text"
                    label="説明（任意・窓口の一覧に表示）"
                  />
                  <p class="sm:col-span-3 text-xs text-zinc-600 dark:text-zinc-400">
                    チャットの URL:
                    <span id="new-app-url" class="font-mono text-indigo-700 dark:text-indigo-300">
                      /{slug_preview(@app_form)}
                    </span>
                    ・管理画面: <span class="font-mono">/{slug_preview(@app_form)}/admin</span>
                  </p>
                  <div class="sm:col-span-3 flex flex-wrap items-center gap-2">
                    <button
                      type="submit"
                      id="create-app-btn"
                      class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium"
                    >
                      窓口を作成
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_new_app"
                      class="px-4 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs"
                    >
                      キャンセル
                    </button>
                    <span class="text-[11px] text-zinc-500">
                      AI の設定は最初の窓口から引き継ぎます。Google Drive と API キーは作成後に設定します。
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
                  窓口「{@last_created_app.name}」（/{@last_created_app.slug}）を作成しました。次に Google Drive のフォルダと認証、必要なら API キーを設定してください。
                </span>
                <a
                  href={"/" <> @last_created_app.slug <> "/admin?tab=settings"}
                  id="open-new-app-settings"
                  class="px-3 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white font-medium"
                >
                  窓口の設定を開く →
                </a>
              </div>

              <div class="overflow-x-auto">
                <table
                  id="apps-table"
                  class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                >
                  <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-2 px-2">窓口名 / 説明</th>
                      <th class="py-2 px-2">URL</th>
                      <th class="py-2 px-2 text-right">文書 / チャンク</th>
                      <th class="py-2 px-2">Drive</th>
                      <th class="py-2 px-2">直近のバッチ</th>
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
                              placeholder="説明（ポータルに表示）"
                              class="w-full px-2 py-1 rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 text-[11px]"
                            />
                            <button type="submit" class="text-[11px] underline text-indigo-600">保存</button>
                          </form>
                          <span :if={is_nil(app.id)} class="font-medium">{app.name}</span>
                        </td>
                        <td class="py-2 px-2 font-mono whitespace-nowrap">
                          <a href={"/" <> app.slug} class="text-indigo-600 underline">/{app.slug}</a>
                          <a href={"/" <> app.slug <> "/admin"} class="ml-2 text-zinc-500 underline">管理</a>
                        </td>
                        <% sum = Map.get(@app_summaries, app.slug, %{}) %>
                        <td class="py-2 px-2 text-right font-mono">
                          {sum[:docs] || 0} / {sum[:chunks] || 0}
                        </td>
                        <td class="py-2 px-2 whitespace-nowrap">
                          <%= if sum[:drive?] do %>
                            設定済み
                          <% else %>
                            <a
                              href={"/" <> app.slug <> "/admin?tab=settings"}
                              class="text-amber-700 dark:text-amber-300 underline"
                            >
                              未設定（設定する）
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
                        </td>
                        <td class="py-2 px-2 text-right whitespace-nowrap space-x-2">
                          <button
                            type="button"
                            phx-click="toggle_reset_app_password"
                            phx-value-app_slug={app.slug}
                            class="text-[11px] text-indigo-600 dark:text-indigo-400 underline"
                          >
                            管理者PW再設定
                          </button>
                          <button
                            :if={not app.primary and app.id}
                            type="button"
                            phx-click="delete_app"
                            phx-value-id={app.id}
                            data-confirm={"窓口「#{app.name}」を削除します。チャット・管理画面が使えなくなります（データベースファイルは名前を変えて残します）。続行しますか？"}
                            class="text-[11px] text-red-600 underline"
                          >
                            削除
                          </button>
                        </td>
                      </tr>
                      <tr
                        :if={@resetting_app_slug == app.slug}
                        class="bg-indigo-50/50 dark:bg-indigo-950/30"
                      >
                        <td colspan="6" class="p-3">
                          <form
                            phx-submit="reset_app_admin_password"
                            class="flex flex-wrap items-center gap-3 text-xs"
                          >
                            <input type="hidden" name="app_slug" value={app.slug} />
                            <span class="font-medium text-zinc-800 dark:text-zinc-200">
                              「{app.name}」の管理者パスワードを再設定:
                            </span>
                            <input
                              type="password"
                              name="new_password"
                              placeholder="新しいパスワード（8文字以上）"
                              required
                              class="px-2.5 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-xs w-48"
                            />
                            <input
                              type="password"
                              name="confirmation"
                              placeholder="確認用パスワード"
                              required
                              class="px-2.5 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-xs w-48"
                            />
                            <button
                              type="submit"
                              class="px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                            >
                              再設定を実行
                            </button>
                            <button
                              type="button"
                              phx-click="toggle_reset_app_password"
                              phx-value-app_slug=""
                              class="px-2.5 py-1.5 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-600 dark:text-zinc-300 text-xs transition"
                            >
                              キャンセル
                            </button>
                          </form>
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
                    <.icon name="hero-users" class="w-5 h-5 text-indigo-600" /> 登録ユーザー
                  </h2>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    利用者は初回ログイン時に自動登録され、全員が一般ユーザーとして開始します。<strong>「昇格可」</strong>に指定されたアカウントだけが、管理者パスワードを入力して一時的に管理者になれます。
                  </p>
                </div>
                <span class="text-xs text-zinc-500 shrink-0">合計 {length(@users)} 名</span>
              </div>

              <%!-- Administrators by e-mail, before their first sign-in too (F-1309) --%>
              <form
                id="grant-admin-form"
                phx-submit="grant_admin_emails"
                class="flex flex-col sm:flex-row gap-2 sm:items-end"
              >
                <label class="flex-1 text-xs space-y-1">
                  <span class="block font-medium text-zinc-700 dark:text-zinc-300">
                    メールアドレスで管理者（昇格可）を追加（複数可・カンマ区切り。まだログインしたことのない人も追加できます）
                  </span>
                  <input
                    type="text"
                    name="emails"
                    required
                    placeholder={
                      if @setting.allowed_domain,
                        do: "name@#{@setting.allowed_domain}, name2@#{@setting.allowed_domain}",
                        else: "name@company.com"
                    }
                    class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                  />
                </label>
                <button
                  type="submit"
                  id="grant-admin-btn"
                  class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                >
                  昇格可にする
                </button>
              </form>

              <%= if Accounts.configured_admin_emails() != [] do %>
                <div class="p-3 rounded-xl bg-zinc-50 dark:bg-zinc-950 border border-zinc-200/60 dark:border-zinc-800 text-xs text-zinc-600 dark:text-zinc-400">
                  <span class="font-medium text-zinc-700 dark:text-zinc-300">
                    環境変数で昇格可に固定されているアドレス:
                  </span>
                  <span class="font-mono text-[11px] ml-1">
                    {Enum.join(Accounts.configured_admin_emails(), ", ")}
                  </span>
                  <p class="text-[11px] text-zinc-400 mt-1">
                    これらはログインのたびに昇格可フラグが再付与されます。画面から外しても元に戻ります。
                  </p>
                </div>
              <% end %>

              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                  <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-3 px-2">ユーザー</th>
                      <th class="py-3 px-2">全体管理者への昇格</th>
                      <th class="py-3 px-2">担当窓口（アプリ管理者）</th>
                      <th class="py-3 px-2">状態</th>
                      <th class="py-3 px-2">最終ログイン / 最終昇格</th>
                      <th class="py-3 px-2 text-right">操作</th>
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
                              (自分)
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
                            {if user.admin_eligible, do: "全体昇格可", else: "不可"}
                          </span>
                        </td>
                        <td class="py-3 px-2">
                          <%= if user.admin_eligible do %>
                            <span class="text-[11px] text-zinc-400">（全窓口の管理が可能）</span>
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
                                      do: "クリックして #{app.name} の管理者権限を解除",
                                      else: "クリックして #{app.name} の管理者権限を付与"
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
                            {if user.status == "active", do: "有効", else: "無効"}
                          </span>
                        </td>
                        <td class="py-3 px-2 text-zinc-400">
                          <div>
                            {if user.last_login_at,
                              do: AskDrive.Clock.format(user.last_login_at, "%Y-%m-%d %H:%M"),
                              else: "—"}
                          </div>
                          <div class="text-[10px]">
                            昇格: {if user.last_elevated_at,
                              do: AskDrive.Clock.format(user.last_elevated_at, "%Y-%m-%d %H:%M"),
                              else: "—"}
                          </div>
                        </td>
                        <td class="py-3 px-2">
                          <%!-- Self-modification and last-admin removal are rejected server
                                side too; hiding the buttons just avoids a pointless error. --%>
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
                                  do: "#{user.email} から管理者への昇格資格を外しますか？",
                                  else:
                                    "#{user.email} に管理者への昇格を許可しますか？管理者パスワードを知っていれば設定と API キーを変更できるようになります。"
                                )
                              }
                              class="px-2.5 py-1 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-[11px] font-medium transition"
                            >
                              {if user.admin_eligible, do: "昇格を禁止", else: "昇格を許可"}
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
                                  do: "#{user.email} を無効化しますか？ログインできなくなります。",
                                  else: "#{user.email} を再度有効化しますか？"
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
                              {if user.status == "active", do: "無効化", else: "有効化"}
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
                管理者権限の昇格履歴
              </h2>
              <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                どのアカウントから、いつ管理者権限へ昇格したかの記録です（直近 100 件）。失敗・解除・期限切れも残ります。この記録は削除も編集もできません。
              </p>
            </div>

            <%= if @elevation_logs == [] do %>
              <p class="text-xs text-zinc-500 py-8 text-center">昇格の記録はまだありません。</p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                  <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-3 px-2">日時</th>
                      <th class="py-3 px-2">アカウント</th>
                      <th class="py-3 px-2">イベント</th>
                      <th class="py-3 px-2">送信元 IP</th>
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
                <p class="text-xs font-medium text-zinc-500">総リクエスト数 (過去30日)</p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {@metrics_summary.total_requests}
                  <span class="text-xs font-normal text-zinc-500">回</span>
                </p>
                <p class="text-[11px] text-zinc-400 mt-1">成功率: {@metrics_summary.success_rate}%</p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">総消費トークン数</p>
                <p class="text-2xl font-bold text-indigo-600 dark:text-indigo-400 mt-1">
                  {@metrics_summary.total_tokens}
                </p>
                <p class="text-[11px] text-zinc-400 mt-1">
                  入力 {@metrics_summary.prompt_tokens} / 出力 {@metrics_summary.completion_tokens}
                </p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">送信データ量</p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {div(@metrics_summary.total_bytes, 1024)}
                  <span class="text-xs font-normal text-zinc-500">KB</span>
                </p>
                <p class="text-[11px] text-zinc-400 mt-1">({@metrics_summary.total_bytes} bytes)</p>
              </div>

              <div class="p-4 rounded-xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm">
                <p class="text-xs font-medium text-zinc-500">平均応答時間 (レイテンシ)</p>
                <p class="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-1">
                  {@metrics_summary.avg_latency_ms}
                  <span class="text-xs font-normal text-zinc-500">ms</span>
                </p>
                <p class="text-[11px] text-zinc-400 mt-1">
                  エラー発生数: {@metrics_summary.error_requests} 件
                </p>
              </div>
            </div>

            <%!-- Provider & Model Breakdown --%>
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4">
                <h3 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" /> プロバイダ・モデル別利用内訳
                </h3>
                <%= if @metrics_summary.provider_breakdown == [] do %>
                  <p class="text-xs text-zinc-500 py-4 text-center">API呼び出しの記録はまだありません。</p>
                <% else %>
                  <div class="overflow-x-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                        <tr>
                          <th class="py-2.5 px-2">プロバイダ</th>
                          <th class="py-2.5 px-2">モデル</th>
                          <th class="py-2.5 px-2 text-right">リクエスト</th>
                          <th class="py-2.5 px-2 text-right">総トークン</th>
                          <th class="py-2.5 px-2 text-right">エラー</th>
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
                  <.icon name="hero-tag" class="w-5 h-5 text-indigo-600" /> 機能・用途別内訳
                </h3>
                <%= if @metrics_summary.purpose_breakdown == [] do %>
                  <p class="text-xs text-zinc-500 py-4 text-center">API呼び出しの記録はまだありません。</p>
                <% else %>
                  <div class="overflow-x-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                        <tr>
                          <th class="py-2.5 px-2">用途</th>
                          <th class="py-2.5 px-2 text-right">リクエスト数</th>
                          <th class="py-2.5 px-2 text-right">総トークン数</th>
                        </tr>
                      </thead>
                      <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                        <%= for row <- @metrics_summary.purpose_breakdown do %>
                          <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-950/50 transition">
                            <td class="py-2.5 px-2 font-medium text-zinc-900 dark:text-zinc-100">
                              {case row.purpose do
                                "batch_generation" -> "夜間バッチ QA生成"
                                "chat_summary" -> "チャット AI要約"
                                "embedding" -> "埋め込みベクトル生成"
                                "generation" -> "テキスト生成"
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
                    直近の API 通信エラーログ（プライバシー配慮: 質問本文や文書内容は保存・表示しません）
                  </h3>
                  <p class="text-xs text-zinc-500 mt-1">
                    直近発生した API 通信エラーの履歴です。API キーの失効やレート制限（429）、タイムアウトなどを確認できます。
                  </p>
                </div>
              </div>

              <%= if @recent_api_errors == [] do %>
                <div class="p-4 rounded-xl bg-emerald-50 dark:bg-emerald-950/30 border border-emerald-200 dark:border-emerald-900 text-xs text-emerald-800 dark:text-emerald-300 flex items-center gap-2">
                  <.icon
                    name="hero-check-circle"
                    class="w-4 h-4 text-emerald-600 dark:text-emerald-400 shrink-0"
                  />
                  <span>直近のエラーは発生していません。正常に稼働しています。</span>
                </div>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                    <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                      <tr>
                        <th class="py-2.5 px-2">日時</th>
                        <th class="py-2.5 px-2">プロバイダ</th>
                        <th class="py-2.5 px-2">モデル</th>
                        <th class="py-2.5 px-2">用途</th>
                        <th class="py-2.5 px-2">エラー内容</th>
                        <th class="py-2.5 px-2 text-right">遅延</th>
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
                    インデックス対象データのトークン効率・構造化分析
                  </h3>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    取り込み文書がどれだけ効率よくトークン化（テキスト抽出・構造化）されているかを分析します。Markdown等の構造化テキストはトークン密度と検索精度が高く、スキャン画像や複雑なPDFはトークン効率が低下する傾向があります。
                  </p>
                </div>
                <div class="text-right shrink-0">
                  <span class="text-xs font-semibold text-zinc-600 dark:text-zinc-300">
                    対象文書: {@data_efficiency.total_indexed_docs} 件
                  </span>
                  <span class="text-[11px] text-zinc-400 block">
                    総インデックス: {@data_efficiency.total_tokens} トークン
                  </span>
                </div>
              </div>

              <%!-- Format Comparison Cards / Table --%>
              <div class="space-y-3">
                <h4 class="text-xs font-semibold text-zinc-700 dark:text-zinc-300">
                  ファイル形式別のトークン効率比較
                </h4>
                <%= if @data_efficiency.format_breakdown == [] do %>
                  <p class="text-xs text-zinc-400 py-3 text-center">インデックス済みの文書がありません。</p>
                <% else %>
                  <div class="overflow-x-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                        <tr>
                          <th class="py-2.5 px-2">形式・種別</th>
                          <th class="py-2.5 px-2 text-right">文書数</th>
                          <th class="py-2.5 px-2 text-right">総トークン数</th>
                          <th class="py-2.5 px-2 text-right">元データ合計</th>
                          <th class="py-2.5 px-2 text-right">トークン密度 (Tokens/KB)</th>
                          <th class="py-2.5 px-2 text-right">有効テキスト比率</th>
                          <th class="py-2.5 px-2">効率評価</th>
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
                                    "最高 (S)"

                                  String.starts_with?(fmt.category, "CSV") or
                                    String.starts_with?(fmt.category, "Docs") or
                                      String.starts_with?(fmt.category, "Sheets") ->
                                    "良好 (A)"

                                  String.starts_with?(fmt.category, "PDF") ->
                                    "標準 (B)"

                                  true ->
                                    "要確認 (C)"
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
                  文書ごとのトークン効率と改善アドバイス
                </h4>
                <%= if @data_efficiency.doc_stats == [] do %>
                  <p class="text-xs text-zinc-400 py-3 text-center">インデックス済みの文書がありません。</p>
                <% else %>
                  <div class="overflow-x-auto max-h-80 overflow-y-auto">
                    <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                      <thead class="text-[11px] uppercase tracking-wider text-zinc-400 border-b border-zinc-200 dark:border-zinc-800 sticky top-0 bg-white dark:bg-zinc-900">
                        <tr>
                          <th class="py-2.5 px-2">ドキュメント</th>
                          <th class="py-2.5 px-2">種別</th>
                          <th class="py-2.5 px-2 text-right">推定トークン</th>
                          <th class="py-2.5 px-2 text-right">元サイズ</th>
                          <th class="py-2.5 px-2">効率スコア</th>
                          <th class="py-2.5 px-2">データ作成者向けアドバイス</th>
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
                                  String.starts_with?(stat.score_rating, "優良") ->
                                    "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

                                  String.starts_with?(stat.score_rating, "良好") ->
                                    "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300"

                                  String.starts_with?(stat.score_rating, "普通") ->
                                    "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

                                  String.starts_with?(stat.score_rating, "要改善") ->
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
                  組織（Google Workspace）
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  Google ログイン（SSO）と Google Drive の連携では、このドメインのアカウントだけを受け付けます。ドメイン全体の委任で「なりすますユーザー」を指定する場合も、このドメインのアドレスである必要があります。
                </p>
              </div>
              <.form for={@form} id="org-form" phx-submit="save_settings" class="space-y-4">
                <.input
                  field={@form[:allowed_domain]}
                  type="text"
                  label="Google Workspace ドメイン（例: company.com）"
                  placeholder="company.com"
                />
                <div class="flex justify-end">
                  <button
                    type="submit"
                    id="save-org-btn"
                    class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                  >
                    保存
                  </button>
                </div>
              </.form>

              <%!-- Sign-in methods (spec 6.13 / F-1310): each on or off on its own --%>
              <h3 class="pt-2 text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                ログインの方法
              </h3>

              <div
                id="oauth-settings"
                class="p-4 rounded-xl border border-zinc-200/80 dark:border-zinc-800 space-y-3"
              >
                <h3 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200 flex items-center gap-2">
                  <.icon name="hero-key" class="w-4 h-4 text-indigo-500" /> Google ログイン（OAuth）
                  <span class={[
                    "text-[11px] font-medium px-2 py-0.5 rounded-full",
                    if(AskDrive.Drive.OAuth.login_enabled?(),
                      do:
                        "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
                      else: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800"
                    )
                  ]}>
                    {cond do
                      AskDrive.Drive.OAuth.get_client_id() == "" -> "未設定"
                      AskDrive.Drive.OAuth.login_enabled?() -> "有効"
                      true -> "無効"
                    end}
                  </span>
                </h3>
                <p class="text-xs text-zinc-500 leading-relaxed">
                  ログイン画面に「Google でログイン」を出します（Google のログイン画面を通るため 2 段階認証がかかります）。Google Cloud Console に承認済みのリダイレクト URI（公開ドメイン）を登録できる環境で使えます。無効にしても認証情報は残り、Drive 同期の OAuth 連携には影響しません。
                </p>
                <.form for={@form} id="oauth-form" phx-submit="save_settings" class="space-y-3">
                  <input type="hidden" name="setting[oauth_login_enabled]" value="false" />
                  <label class="flex items-center gap-2 text-sm text-zinc-800 dark:text-zinc-200">
                    <input
                      type="checkbox"
                      name="setting[oauth_login_enabled]"
                      value="true"
                      checked={@setting.oauth_login_enabled != false}
                      class="rounded border-zinc-300"
                    /> Google ログインを有効にする
                  </label>
                  <div class="space-y-3">
                    <h3 class="font-semibold text-xs text-zinc-700 dark:text-zinc-300 flex items-center gap-1.5">
                      <.icon name="hero-key" class="w-4 h-4 text-indigo-500" /> 認証情報
                    </h3>
                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                      <.input
                        field={@form[:google_client_id]}
                        type="text"
                        label="OAuth クライアント ID (Client ID)"
                        placeholder="例: xxxxxxxx.apps.googleusercontent.com"
                      />
                      <.input
                        field={@form[:google_client_secret]}
                        type="password"
                        value=""
                        label={"OAuth クライアント シークレット（#{secret_state(@setting.google_client_secret)}）"}
                        placeholder="例: GOCSPX-xxxxxxxxxxxx"
                      />
                    </div>
                    <p class="text-xs text-zinc-500">
                      Google Cloud Console に登録する「承認済みのリダイレクト URI」:
                      <span class="font-mono text-indigo-600 dark:text-indigo-400 select-all">
                        https://&lt;ホスト名&gt;:{AskDrive.SSL.https_port()}/auth/google/callback
                      </span>
                    </p>
                  </div>
                  <div class="flex justify-end">
                    <button
                      type="submit"
                      id="save-oauth-btn"
                      class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                    >
                      保存
                    </button>
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
                    Google Secure LDAP でのログイン
                    <span class={[
                      "text-[11px] font-medium px-2 py-0.5 rounded-full",
                      if(AskDrive.Ldap.enabled?(@setting),
                        do:
                          "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
                        else: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800"
                      )
                    ]}>
                      {if AskDrive.Ldap.enabled?(@setting), do: "有効", else: "無効"}
                    </span>
                  </h2>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    ログイン画面に「メールアドレスとパスワード」の欄を出し、Google Workspace のパスワードを Secure LDAP で確認します（パスワードは AskDrive に保存しません）。外部公開の URL がなくても使えます。Google 管理コンソールで LDAP クライアントを追加し、「ユーザー認証情報の確認」と「ユーザー情報の読み取り」を許可して、発行された証明書（.crt）と秘密鍵（.key）をここに登録してください。
                  </p>
                  <p class="text-xs text-amber-700 dark:text-amber-300 mt-1 leading-relaxed">
                    LDAP でのパスワード確認には Google の 2 段階認証がかかりません。同じアカウントで 5 分間に 5 回失敗すると 15 分、同じ接続環境（ブラウザ）から 24 時間に 10 回失敗すると 24 時間ロックします。
                  </p>
                </div>

                <% ldap_cert =
                  @setting.ldap_client_cert && AskDrive.SSL.describe_cert(@setting.ldap_client_cert) %>
                <div class="text-xs text-zinc-600 dark:text-zinc-400 space-y-0.5">
                  <%= case ldap_cert do %>
                    <% {:ok, info} -> %>
                      <p id="ldap-cert-info">
                        登録済みの証明書: <span class="font-mono">{info["subject"]}</span>・有効期限 {String.slice(
                          info["not_after"],
                          0,
                          10
                        )}
                      </p>
                    <% _ -> %>
                      <p>クライアント証明書: 未登録</p>
                  <% end %>
                  <p>
                    秘密鍵: {secret_state(@setting.ldap_client_key)}・CA 証明書: {if @setting.ldap_ca_cert,
                      do: "登録済み",
                      else: "なし（公的な CA で検証）"}
                  </p>
                </div>

                <form id="ldap-form" phx-submit="save_ldap" phx-change="ldap_change" class="space-y-4">
                  <label class="flex items-center gap-2 text-sm text-zinc-800 dark:text-zinc-200">
                    <input type="hidden" name="ldap[ldap_enabled]" value="false" />
                    <input
                      type="checkbox"
                      name="ldap[ldap_enabled]"
                      value="true"
                      checked={@ldap_form["ldap_enabled"] == "true"}
                      class="rounded border-zinc-300"
                    /> LDAP でのログインを有効にする
                  </label>
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
                    <label class="space-y-1 sm:col-span-2">
                      <span class="block font-medium">LDAP サーバー</span>
                      <input
                        type="text"
                        name="ldap[ldap_host]"
                        value={@ldap_form["ldap_host"]}
                        placeholder={AskDrive.Ldap.default_host()}
                        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                      />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">ポート（LDAPS）</span>
                      <input
                        type="number"
                        name="ldap[ldap_port]"
                        value={@ldap_form["ldap_port"]}
                        placeholder={AskDrive.Ldap.default_port()}
                        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                      />
                    </label>
                    <label class="space-y-1 sm:col-span-3">
                      <span class="block font-medium">ベース DN（空欄ならドメインから自動: {AskDrive.Ldap.domain_base_dn(
                        @setting.allowed_domain
                      ) || "ドメイン未設定"}）</span>
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
                      <span class="block font-medium">クライアント証明書（.crt）</span>
                      <.live_file_input upload={@uploads.ldap_cert} class={ssl_file_input_class()} />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">秘密鍵（.key）</span>
                      <.live_file_input upload={@uploads.ldap_key} class={ssl_file_input_class()} />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">CA 証明書（任意・Google では不要）</span>
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
                    /> 登録済みの CA 証明書を削除する
                  </label>
                  <details class="text-xs">
                    <summary class="cursor-pointer text-zinc-500">アクセス認証情報（任意）</summary>
                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mt-2">
                      <label class="space-y-1">
                        <span class="block font-medium">ユーザー名（バインド DN）</span>
                        <input
                          type="text"
                          name="ldap[ldap_bind_dn]"
                          value={@ldap_form["ldap_bind_dn"]}
                          class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                        />
                      </label>
                      <label class="space-y-1">
                        <span class="block font-medium">パスワード（{secret_state(
                          @setting.ldap_bind_password
                        )}）</span>
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
                      Google では証明書だけで接続できるため通常は不要です。管理コンソールで「アクセス認証情報」を生成した場合に入力します。
                    </p>
                  </details>
                  <p
                    :if={@ldap_pending != %{}}
                    id="ldap-pending"
                    class="text-xs text-amber-700 dark:text-amber-300"
                  >
                    選択済み・未保存: {@ldap_pending
                    |> Enum.map(fn {_kind, {name, _pem}} -> name end)
                    |> Enum.join("、")}（「保存」で登録されます）
                  </p>
                  <div class="flex flex-wrap justify-end gap-2">
                    <button
                      type="submit"
                      name="op"
                      value="test"
                      id="test-ldap-btn"
                      class="px-4 py-2.5 rounded-xl border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium text-xs transition"
                    >
                      接続テスト（入力中の内容で）
                    </button>
                    <button
                      type="submit"
                      name="op"
                      value="save"
                      id="save-ldap-btn"
                      class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                    >
                      保存
                    </button>
                  </div>
                </form>

                <%!-- Active sign-in locks (spec F-1305), liftable by an administrator --%>
                <div
                  id="login-locks"
                  class="pt-3 border-t border-zinc-200/60 dark:border-zinc-800 space-y-2"
                >
                  <h3 class="text-xs font-semibold text-zinc-600 dark:text-zinc-300">
                    ロック中のログイン（{length(@login_locks)} 件）
                  </h3>
                  <p :if={@login_locks == []} class="text-xs text-zinc-400">ロック中のアカウント・接続環境はありません。</p>
                  <table
                    :if={@login_locks != []}
                    class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400"
                  >
                    <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                      <tr>
                        <th class="py-1.5 px-2">対象</th>
                        <th class="py-1.5 px-2">接続環境</th>
                        <th class="py-1.5 px-2">解除予定</th>
                        <th class="py-1.5 px-2"></th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                      <tr :for={lock <- @login_locks} id={"login-lock-#{lock.id}"}>
                        <td class="py-1.5 px-2">
                          {cond do
                            lock.scope == "account" and String.starts_with?(lock.key, "access:") ->
                              "窓口「#{lock.key |> String.trim_leading("access:") |> String.split("|") |> hd()}」の合言葉（5 分間に 5 回失敗）"

                            lock.scope == "account" ->
                              "アカウント: #{lock.email}（5 分間に 5 回失敗）"

                            true ->
                              "接続環境（24 時間に 10 回失敗）"
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
                            data-confirm="このロックを解除しますか？"
                            class="px-2.5 py-1 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 font-medium"
                          >
                            解除
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
                    :ok -> "接続できました（証明書・ベース DN とも OK）。ログイン画面でパスワードを試してください。"
                    {:error, message} -> "接続できません: " <> message
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
                  <.icon name="hero-user-circle" class="w-5 h-5 text-indigo-600" /> ログイン認証
                  <span class={[
                    "text-[11px] font-medium px-2 py-0.5 rounded-full",
                    if(auth_state == :enabled,
                      do:
                        "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
                      else: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"
                    )
                  ]}>
                    {if auth_state == :enabled, do: "有効", else: "無効（ゲスト・POC）"}
                  </span>
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  有効にすると、窓口一覧・チャットを含むすべての画面でログインが必要になり、管理画面はさらに管理者パスワードでの昇格が必要になります。無効の間は、誰でもログインなしでチャットと管理画面を使えます。締め出された場合は、サーバー上で
                  <code class="font-mono">./app.sh auth disable</code>
                  を実行すると無効に戻せます。
                </p>
              </div>

              <p
                :if={auth_source == :env}
                id="auth-env-fixed"
                class="text-xs px-3 py-2 rounded-lg bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300"
              >
                環境変数 <code class="font-mono">ASK_DRIVE_DISABLE_AUTH</code>（.env.prod）で固定されています。この画面や ./app.sh auth で切り替えるには、.env.prod からその行を削除して再起動してください。
              </p>

              <form
                :if={auth_source != :env && auth_state == :disabled}
                id="enable-auth-form"
                phx-submit="enable_auth"
                class="space-y-3"
              >
                <label class="block text-xs space-y-1">
                  <span class="block font-medium text-zinc-700 dark:text-zinc-300">
                    管理者のメールアドレス（複数可・カンマ区切り。有効にした後、このいずれかでログインして昇格します）
                  </span>
                  <input
                    type="text"
                    name="admin_email"
                    required
                    placeholder={
                      if @setting.allowed_domain,
                        do: "name@#{@setting.allowed_domain}, name2@#{@setting.allowed_domain}",
                        else: "name@company.com, name2@company.com"
                    }
                    class="w-full sm:w-96 px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950"
                  />
                </label>
                <p class="text-xs text-zinc-500">
                  必要なもの: ログインの方法（Google Secure LDAP または Google ログイン）が設定済みで、管理者パスワードが設定済みであること。有効にすると、このブラウザもログイン画面に移ります。
                </p>
                <button
                  type="submit"
                  id="enable-auth-btn"
                  data-confirm="ログイン認証を有効にしますか？有効にした後は、ログインと管理者パスワードでの昇格をしないと管理画面に入れません。"
                  class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                >
                  ログイン認証を有効にする
                </button>
              </form>

              <div :if={auth_source != :env && auth_state == :enabled} class="flex justify-end">
                <button
                  id="disable-auth-btn"
                  phx-click="disable_auth"
                  data-confirm="ログイン認証を無効にしますか？誰でもログインなしでチャットと管理画面を使えるようになります。"
                  class="px-4 py-2.5 rounded-xl border border-red-300 text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950/40 font-medium text-xs transition"
                >
                  ログイン認証を無効にする（ゲスト・POC に戻す）
                </button>
              </div>
            </div>

            <%!-- Card 1: Administrator password --%>
            <div
              :if={@scope == :platform}
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-shield-check" class="w-5 h-5 text-indigo-600" /> 管理者パスワード
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  管理画面へ昇格する際に入力するパスワードです。昇格可能なアカウント全員で共有します。退職者が出たときや漏洩が疑われるときは変更してください。
                </p>
              </div>

              <.form
                for={@password_form}
                id="admin-password-form"
                phx-submit="change_admin_password"
                class="grid grid-cols-1 sm:grid-cols-3 gap-4 items-end"
              >
                <.input
                  field={@password_form[:current]}
                  type="password"
                  value=""
                  label="現在のパスワード"
                  autocomplete="current-password"
                />
                <.input
                  field={@password_form[:new]}
                  type="password"
                  value=""
                  label={"新しいパスワード（#{AdminAccess.min_password_length()} 文字以上）"}
                  autocomplete="new-password"
                />
                <div class="flex items-end gap-3">
                  <div class="flex-1">
                    <.input
                      field={@password_form[:confirmation]}
                      type="password"
                      value=""
                      label="確認"
                      autocomplete="new-password"
                    />
                  </div>
                  <button
                    type="submit"
                    id="change-admin-password-btn"
                    class="px-4 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition whitespace-nowrap"
                  >
                    変更
                  </button>
                </div>
              </.form>

              <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 pt-2 border-t border-zinc-200/60 dark:border-zinc-800">
                <.input
                  field={@form[:admin_session_minutes]}
                  type="number"
                  label="昇格の有効時間 (分)"
                  min="1"
                  max="480"
                  form="settings-form"
                />
                <.input
                  field={@form[:admin_max_attempts]}
                  type="number"
                  label="管理者パスワードの入力ミス: ロックまでの回数"
                  min="1"
                  max="50"
                  form="settings-form"
                />
                <.input
                  field={@form[:admin_lockout_minutes]}
                  type="number"
                  label="管理者パスワードの入力ミス: ロック時間 (分)"
                  min="1"
                  max="1440"
                  form="settings-form"
                />
              </div>
              <p class="text-[11px] text-zinc-400">
                上記 3 項目は下の「設定を保存」で反映されます。入力ミスのロックは管理者への昇格（管理者パスワード）に対するもので、LDAP ログインのロックは「組織」→「Google Secure LDAP でのログイン」に記載のとおり別に働きます。
              </p>
            </div>

            <%!-- Card 1b: App Administrator Password (for App scope) --%>
            <div
              :if={@scope == :app}
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-shield-check" class="w-5 h-5 text-indigo-600" /> 窓口管理者パスワード
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  この窓口（{@app.name}）の管理画面へ昇格する際に入力するパスワードです。未設定時はプラットフォーム管理者パスワードで昇格できます。
                </p>
              </div>

              <.form
                for={@password_form}
                id="app-admin-password-form"
                phx-submit="change_admin_password"
                class="grid grid-cols-1 sm:grid-cols-3 gap-4 items-end"
              >
                <.input
                  field={@password_form[:current]}
                  type="password"
                  value=""
                  label="現在のパスワード"
                  autocomplete="current-password"
                />
                <.input
                  field={@password_form[:new]}
                  type="password"
                  value=""
                  label={"新しいパスワード（#{AdminAccess.min_password_length()} 文字以上）"}
                  autocomplete="new-password"
                />
                <div class="flex items-end gap-3">
                  <div class="flex-1">
                    <.input
                      field={@password_form[:confirmation]}
                      type="password"
                      value=""
                      label="確認"
                      autocomplete="new-password"
                    />
                  </div>
                  <button
                    type="submit"
                    id="change-app-admin-password-btn"
                    class="px-4 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition whitespace-nowrap"
                  >
                    変更
                  </button>
                </div>
              </.form>
            </div>

            <%!-- Card 1c: App Access Password (合言葉 / 利用制限) --%>
            <div
              :if={@scope == :app}
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                    <.icon name="hero-lock-closed" class="w-5 h-5 text-indigo-600" /> 窓口アクセスパスワード（合言葉）
                  </h2>
                  <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                    この窓口のチャット利用を限定するための合言葉です。有効にすると、正しい合言葉を入力したユーザーのみがチャットを利用できるようになります。
                  </p>
                </div>
                <div>
                  <span class={[
                    "text-xs px-2.5 py-1 rounded-full font-medium inline-flex items-center gap-1.5",
                    if(@setting.access_password_enabled,
                      do:
                        "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300 border border-emerald-200 dark:border-emerald-800",
                      else:
                        "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400 border border-zinc-200 dark:border-zinc-700"
                    )
                  ]}>
                    <span class="w-1.5 h-1.5 rounded-full bg-current"></span>
                    {if @setting.access_password_enabled, do: "利用制限: 有効", else: "利用制限: 無効"}
                  </span>
                </div>
              </div>

              <.form
                for={@access_password_form}
                id="access-password-form"
                phx-submit="save_access_password"
                class="grid grid-cols-1 sm:grid-cols-3 gap-4 items-end"
              >
                <input type="hidden" name="access_password[enabled]" value="true" />
                <.input
                  field={@access_password_form[:password]}
                  type="password"
                  value=""
                  label={"#{if @setting.access_password_enabled, do: "新しい合言葉", else: "合言葉（アクセスパスワード）"}（#{AdminAccess.min_password_length()} 文字以上）"}
                  autocomplete="new-password"
                  required
                />
                <div class="flex items-end gap-3 sm:col-span-2">
                  <div class="flex-1">
                    <.input
                      field={@access_password_form[:confirmation]}
                      type="password"
                      value=""
                      label="確認"
                      autocomplete="new-password"
                      required
                    />
                  </div>
                  <button
                    type="submit"
                    id="save-access-password-btn"
                    class="px-4 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition whitespace-nowrap"
                  >
                    {if @setting.access_password_enabled, do: "合言葉を変更", else: "合言葉を設定して有効化"}
                  </button>
                  <button
                    :if={@setting.access_password_enabled}
                    type="button"
                    id="disable-access-password-btn"
                    phx-click="disable_access_password"
                    data-confirm="合言葉による利用制限を無効化しますか？"
                    class="px-4 py-2.5 rounded-xl border border-zinc-300 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-300 font-medium text-xs transition whitespace-nowrap"
                  >
                    利用制限を解除
                  </button>
                </div>
              </.form>
            </div>

            <%!-- Card 2: Google Drive Sync Authentication --%>
            <div
              :if={@scope == :app}
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div class="flex items-center justify-between">
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cloud-arrow-down" class="w-5 h-5 text-indigo-600" />
                  Google Drive 同期認証
                </h2>
                <%= if Accounts.drive_connected?() do %>
                  <span class="text-xs px-2.5 py-1 rounded-full font-medium bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300 border border-emerald-200/50">
                    連携中: {Accounts.drive_identity()}
                  </span>
                <% else %>
                  <span class="text-xs px-2.5 py-1 rounded-full font-medium bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300 border border-amber-200/50">
                    未連携
                  </span>
                <% end %>
              </div>

              <div class="flex gap-2 p-1 rounded-xl bg-zinc-100 dark:bg-zinc-800 w-fit text-xs font-medium">
                <button
                  type="button"
                  id="drive-auth-mode-oauth"
                  phx-click="set_drive_auth_mode"
                  phx-value-mode="oauth"
                  class={[
                    "px-3 py-1.5 rounded-lg transition",
                    if(@setting.drive_auth_mode == "oauth",
                      do: "bg-white dark:bg-zinc-900 shadow-sm text-zinc-900 dark:text-zinc-100",
                      else: "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
                    )
                  ]}
                >
                  OAuth（専用アカウント）
                </button>
                <button
                  type="button"
                  id="drive-auth-mode-service-account"
                  phx-click="set_drive_auth_mode"
                  phx-value-mode="service_account"
                  class={[
                    "px-3 py-1.5 rounded-lg transition",
                    if(@setting.drive_auth_mode == "service_account",
                      do: "bg-white dark:bg-zinc-900 shadow-sm text-zinc-900 dark:text-zinc-100",
                      else: "text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
                    )
                  ]}
                >
                  サービスアカウント
                </button>
              </div>

              <%= if @setting.drive_auth_mode == "service_account" do %>
                <p class="text-xs text-zinc-500 leading-relaxed">
                  ブラウザでの認可が不要なため、Google の redirect_uri 制限（生の IP アドレスや
                  <code
                    class="font-mono text-[11px]"
                    phx-no-curly-interpolation
                  >.local</code>
                  ホスト名の拒否）を回避できます。
                  <a
                    href="https://console.cloud.google.com/iam-admin/serviceaccounts"
                    target="_blank"
                    class="text-indigo-600 dark:text-indigo-400 underline"
                  >
                    Google Cloud Console
                  </a>
                  でサービスアカウントを作成し、JSON キーをダウンロードして貼り付けてください。作成後、同期対象の Drive フォルダをそのサービスアカウントのメールアドレス（<code
                    class="font-mono text-[11px]"
                    phx-no-curly-interpolation
                  >...@...iam.gserviceaccount.com</code>
                  ）と共有するのを忘れないでください。
                </p>

                <.form
                  for={@form}
                  id="service-account-form"
                  phx-submit="save_service_account"
                  class="space-y-3"
                >
                  <.input
                    field={@form[:drive_service_account_json]}
                    type="textarea"
                    value=""
                    rows="6"
                    label={"サービスアカウントの JSON キー（#{secret_state(@setting.drive_service_account_json)}）"}
                    placeholder={
                      ~s({"type": "service_account", "client_email": "...", "private_key": "...", ...})
                    }
                    class="font-mono text-[11px]"
                  />
                  <p class="text-[11px] text-zinc-500 -mt-1">
                    保存済みの場合は空欄のままで構いません（既存のキーを維持します）。
                  </p>
                  <.input
                    field={@form[:drive_impersonate_email]}
                    type="email"
                    label="なりすますユーザー（ドメイン全体の委任・任意）"
                    placeholder="sync@example.com"
                  />
                  <p class="text-[11px] text-zinc-500 leading-relaxed -mt-1">
                    同期対象が「組織内のユーザーのみアクセス可」の共有ドライブにある場合、サービスアカウント（組織外扱い）は共有に追加できません。
                    その場合はフォルダを閲覧できる社内ユーザーのメールアドレスを入力し、Google 管理コンソール →「セキュリティ」→「API の制御」→「ドメイン全体の委任」で
                    クライアント ID
                    <code class="font-mono">{service_account_client_id(@setting) ||
                      "（JSON キーの client_id）"}</code>
                    にスコープ
                    <code class="font-mono" phx-no-curly-interpolation>https://www.googleapis.com/auth/drive.readonly</code>
                    を許可してください。空欄ならサービスアカウント自身としてアクセスします。
                  </p>
                  <div class="flex flex-wrap items-center gap-3">
                    <button
                      type="submit"
                      id="save-service-account-btn"
                      class="inline-flex items-center gap-1.5 px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                    >
                      <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> 保存
                    </button>
                    <button
                      type="button"
                      id="test-service-account-btn"
                      phx-click="test_service_account"
                      class="px-3 py-2 rounded-xl border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium transition"
                    >
                      接続テスト
                    </button>
                    <button
                      :if={Accounts.drive_connected?()}
                      type="button"
                      id="disconnect-service-account-btn"
                      phx-click="disconnect_service_account"
                      data-confirm="保存済みのサービスアカウント認証情報を削除しますか？"
                      class="inline-flex items-center gap-1.5 px-3 py-2 rounded-xl bg-red-50 hover:bg-red-100 text-red-700 dark:bg-red-950/40 dark:hover:bg-red-900/60 dark:text-red-300 font-medium text-xs transition"
                    >
                      <.icon name="hero-x-circle" class="w-4 h-4" /> 削除
                    </button>
                  </div>
                  <%= case @service_account_test do %>
                    <% {:ok, message} -> %>
                      <p class="text-[11px] text-emerald-600 dark:text-emerald-400">{message}</p>
                    <% {:error, message} -> %>
                      <p class="text-[11px] text-red-600 dark:text-red-400">{message}</p>
                    <% _ -> %>
                  <% end %>
                </.form>
              <% else %>
                <p class="text-xs text-zinc-500 leading-relaxed">
                  全社公開マニュアル等の Google Drive フォルダにアクセス可能な <strong>システム管理用アカウント（または専用同期アカウント）</strong>
                  で連携してください。<br /> ※ 一般ユーザーがチャット画面で質問する際は、各自の通常アカウントで利用します。
                </p>

                <div class="flex flex-wrap items-center gap-3 pt-2">
                  <.link
                    href={
                      ~p"/auth/google/drive?#{[return_to: @base_path <> "/admin?tab=settings", app: @app && @app.slug]}"
                    }
                    class="inline-flex items-center gap-2 px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                  >
                    <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4" />
                    {if @account, do: "専用 Google アカウントを再認可", else: "専用 Google アカウントで認可"}
                  </.link>

                  <%= if @account do %>
                    <.link
                      href={
                        ~p"/auth/google/disconnect?#{[return_to: @base_path <> "/admin?tab=settings", app: @app && @app.slug]}"
                      }
                      class="inline-flex items-center gap-1.5 px-4 py-2 rounded-xl bg-red-50 hover:bg-red-100 text-red-700 dark:bg-red-950/40 dark:hover:bg-red-900/60 dark:text-red-300 font-medium text-xs transition"
                    >
                      <.icon name="hero-x-circle" class="w-4 h-4" /> 連携解除
                    </.link>
                  <% end %>
                </div>

                <p class="text-[11px] text-amber-700 dark:text-amber-300 leading-relaxed pt-1">
                  <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5 inline" />
                  この方式は Google Cloud Console にブラウザでアクセスした URL と完全一致するリダイレクト URI の登録が必要です。生の IP アドレスや
                  <code
                    class="font-mono text-[10px]"
                    phx-no-curly-interpolation
                  >.local</code>
                  ホスト名は Google 側で拒否されます。LAN 内からの利用でこの制約を避けたい場合は上の「サービスアカウント」を選んでください。
                </p>
              <% end %>
            </div>

            <%!-- Card 3: LLM Provider Settings --%>
            <div
              :if={@scope == :app}
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-5"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-indigo-600" /> LLM プロバイダ
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  回答生成と埋め込みで別々のプロバイダを選べます。埋め込みをローカルのまま据え置くと再インデックスが不要なため、まず生成だけを切り替える構成をおすすめします。
                </p>
              </div>

              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <%= for {role, label, provider, model} <- [
                      {:generation, "回答生成", @generation_provider, LLM.generation_model(@setting)},
                      {:embedding, "埋め込み", @embedding_provider, @setting.embed_model}
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
                        {if LLM.local?(provider), do: "ローカル", else: "外部 API"}
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
                      API キー: {LLM.masked_api_key(provider, @setting)}
                    </div>

                    <div class="pt-1 flex items-center gap-2">
                      <button
                        type="button"
                        id={"test-#{role}-btn"}
                        phx-click="test_connection"
                        phx-value-role={role}
                        class="px-2.5 py-1 rounded-lg border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-[11px] font-medium transition"
                      >
                        接続テスト
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
                  外部 API が有効です。<strong>文書本文と質問がプロバイダに送信されます。</strong>
                  機密文書を扱う場合は Ollama または LM Studio に戻してください。
                </span>
              </div>

              <p class="text-[11px] text-zinc-400">
                値の変更は下の「システム・OAuth・バッチ設定」フォームから行います。
              </p>
            </div>

            <%!-- Card 4: System Settings Form --%>
            <div class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-6">
              <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                <.icon name="hero-cog-6-tooth" class="w-5 h-5 text-indigo-600" />
                {if @scope == :platform, do: "夜間バッチの時間帯", else: "AI・Drive・チャットの設定"}
              </h2>

              <.form for={@form} id="settings-form" phx-submit="save_settings" class="space-y-5">
                <%!-- LLM Provider Selection --%>
                <div
                  :if={@scope == :app}
                  class="space-y-3 p-4 rounded-xl bg-zinc-50 dark:bg-zinc-950/60 border border-zinc-200/60 dark:border-zinc-800"
                >
                  <h3 class="font-semibold text-xs text-zinc-700 dark:text-zinc-300 flex items-center gap-1.5">
                    <.icon name="hero-cpu-chip" class="w-4 h-4 text-indigo-500" /> LLM プロバイダとモデル
                  </h3>

                  <%!-- Nightly batch: local LLM or cloud API (spec F-821). Both configurations
                        are kept so switching doesn't mean retyping model names. --%>
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    <.input
                      field={@form[:batch_llm_mode]}
                      type="select"
                      label="夜間バッチ（QA 生成）の実行方法"
                      options={[{"ローカル LLM", "local"}, {"クラウド API", "cloud"}]}
                    />
                    <.input
                      field={@form[:llm_max_tokens]}
                      type="number"
                      label="生成トークン上限 (外部 API)"
                      min="1"
                    />
                    <p class="text-[11px] text-zinc-500 leading-relaxed sm:pt-6">
                      クラウド API は高精度・高速ですが、夜間に全チャンクの本文が API 提供元に送信され、従量課金になります。
                    </p>
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:llm_provider]}
                      type="select"
                      label="ローカル LLM プロバイダ"
                      options={
                        provider_options(Enum.filter(LLM.generation_providers(), &LLM.local?/1))
                      }
                    />
                    <.input
                      field={@form[:batch_model]}
                      type="text"
                      label="ローカル LLM のモデル名"
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:cloud_llm_provider]}
                      type="select"
                      label="クラウド API プロバイダ"
                      options={provider_options(AskDrive.Settings.Setting.cloud_providers())}
                    />
                    <.input
                      field={@form[:cloud_llm_model]}
                      type="text"
                      label="クラウド API のモデル名"
                      placeholder="例: Gemini のモデル名"
                    />
                  </div>

                  <%!-- Chat answers can use their own (fast, cloud) provider while the
                        nightly batch keeps generating locally (spec F-415). --%>
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    <.input
                      field={@form[:chat_summary_provider]}
                      type="select"
                      label="チャット要約プロバイダ"
                      prompt="回答生成と同じ"
                      options={provider_options(LLM.generation_providers())}
                    />
                    <.input
                      field={@form[:chat_summary_model]}
                      type="text"
                      label="チャット要約モデル名"
                      placeholder="空欄なら生成モデル名"
                    />
                    <p class="text-[11px] text-zinc-500 leading-relaxed sm:pt-6">
                      夜間バッチ（QA 生成）は上の回答生成プロバイダ、チャットの要約はこちらを使います。クラウドを選ぶと、質問と検索された抜粋が API 提供元に送信されます。
                    </p>
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    <.input
                      field={@form[:embed_provider]}
                      type="select"
                      label="埋め込みプロバイダ"
                      options={provider_options(LLM.embedding_providers())}
                    />
                    <.input field={@form[:embed_model]} type="text" label="埋め込みモデル名" />
                    <.input
                      field={@form[:embedding_dim]}
                      type="number"
                      label="埋め込み次元"
                      min="64"
                      max="4096"
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:batch_num_ctx]}
                      type="number"
                      label="コンテキスト長 (num_ctx / Ollama のみ)"
                    />
                    <.input
                      field={@form[:llm_temperature]}
                      type="number"
                      step="0.1"
                      min="0.0"
                      max="2.0"
                      label="temperature (空欄でプロバイダ既定値)"
                    />
                  </div>

                  <p class="text-[11px] text-amber-700 dark:text-amber-300 leading-relaxed">
                    <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5 inline" />
                    埋め込みモデルまたは次元を変更すると、ベクトル仮想テーブルを再作成し、既存のベクトルをすべて破棄します。次回の夜間バッチで全チャンクを再ベクトル化するまで Tier 1 / Tier 2 は機能しません。
                  </p>
                </div>

                <%!-- Provider Endpoints and API Keys --%>
                <div
                  :if={@scope == :app}
                  class="space-y-3 p-4 rounded-xl bg-zinc-50 dark:bg-zinc-950/60 border border-zinc-200/60 dark:border-zinc-800"
                >
                  <h3 class="font-semibold text-xs text-zinc-700 dark:text-zinc-300 flex items-center gap-1.5">
                    <.icon name="hero-key" class="w-4 h-4 text-indigo-500" /> プロバイダ接続情報
                  </h3>
                  <p class="text-[11px] text-zinc-500">
                    API キーは暗号化して保存されます。空欄のまま保存すると既存の値を維持します。使用しないプロバイダの欄は空のままで構いません。
                  </p>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:ollama_host]}
                      type="text"
                      label="Ollama エンドポイント"
                      placeholder={LLM.default_base_url("ollama")}
                    />
                    <.input
                      field={@form[:lmstudio_base_url]}
                      type="text"
                      label="LM Studio エンドポイント"
                      placeholder={LLM.default_base_url("lmstudio")}
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:anthropic_api_key]}
                      type="password"
                      value=""
                      label={"Anthropic Claude API キー（#{LLM.masked_api_key("anthropic", @setting)}）"}
                      placeholder="sk-ant-..."
                    />
                    <.input
                      field={@form[:anthropic_base_url]}
                      type="text"
                      label="Anthropic ベース URL"
                      placeholder={LLM.default_base_url("anthropic")}
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:gemini_api_key]}
                      type="password"
                      value=""
                      label={"Google Gemini API キー（#{LLM.masked_api_key("gemini", @setting)}）"}
                      placeholder="AIza..."
                    />
                    <.input
                      field={@form[:gemini_base_url]}
                      type="text"
                      label="Gemini ベース URL"
                      placeholder={LLM.default_base_url("gemini")}
                    />
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <.input
                      field={@form[:openai_api_key]}
                      type="password"
                      value=""
                      label={"OpenAI API キー（#{LLM.masked_api_key("openai", @setting)}）"}
                      placeholder="sk-..."
                    />
                    <.input
                      field={@form[:openai_base_url]}
                      type="text"
                      label="OpenAI ベース URL"
                      placeholder={LLM.default_base_url("openai")}
                    />
                  </div>
                </div>

                <%!-- Drive & Domain Settings: per app (folder, threshold, chat) vs platform
                      (allowed domain, nightly window) — spec 6.11 --%>
                <div :if={@scope == :app} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <.input
                    field={@form[:drive_folder_id]}
                    type="text"
                    label="Google Drive フォルダ ID / URL (drive_folder_id)"
                  />
                  <.input
                    field={@form[:drive_folder_name]}
                    type="text"
                    label="Drive フォルダ表示名 (drive_folder_name)"
                  />
                </div>

                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <.input
                    :if={@scope == :app}
                    field={@form[:tier1_threshold]}
                    type="number"
                    step="0.01"
                    min="0.5"
                    max="1.0"
                    label="QA 即答（Tier 1）の類似度しきい値（既定 0.90。下げるほど生成済み QA で即答しやすく、上げるほど要約・抜粋に回る）"
                  />
                </div>

                <div :if={@scope == :platform} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <.input
                    field={@form[:batch_start_hour]}
                    type="number"
                    label="自動実行の開始時刻 (時: 0〜23。既定 0)"
                    min="0"
                    max="23"
                  />
                  <.input
                    field={@form[:batch_end_hour]}
                    type="number"
                    label="自動実行を開始できる最終時刻 (時: 0〜23。既定 7)"
                    min="0"
                    max="23"
                  />
                  <.input
                    field={@form[:batch_deadline_hour]}
                    type="number"
                    label="バッチの打ち切り時刻 (時: 0〜23。既定 8。実行中のバッチはこの時刻で QA 生成を止める)"
                    min="0"
                    max="23"
                  />
                </div>

                <.input
                  :if={@scope == :app}
                  field={@form[:maintenance_message]}
                  type="text"
                  label="メンテナンス告知メッセージ"
                />

                <div
                  :if={@scope == :app}
                  class="pt-2 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3"
                >
                  <.input
                    field={@form[:maintenance_mode]}
                    type="checkbox"
                    label="メンテナンスモード（チャット画面を停止し告知を表示する）"
                  />
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
                  <.input
                    field={@form[:chat_summary_enabled]}
                    type="checkbox"
                    label="チャットで検索結果の AI 要約を表示する（回答生成プロバイダを使用。クラウドの場合は抜粋が社外に送信されます）"
                  />
                </div>

                <div class="pt-4 flex justify-end">
                  <button
                    type="submit"
                    id="save-settings-btn"
                    data-confirm={
                      @scope == :app &&
                        "設定を保存します。埋め込みモデルまたは次元を変更した場合、ベクトルインデックスを再作成し全件の再ベクトル化が必要になります。続行しますか？"
                    }
                    class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                  >
                    設定を保存
                  </button>
                </div>
              </.form>
            </div>

            <%!-- Local models (Ollama) — pulled by the app itself, spec F-827 --%>
            <div
              id="ollama-models"
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-arrow-down-tray" class="w-5 h-5 text-indigo-600" />
                  ローカルモデル（Ollama）
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  Ollama はアプリ専用のため、モデルはここ（またはアプリの起動時）に AskDrive が取得します。設定で使うモデルが未取得なら、起動時・設定の保存時に自動で取得を始めます。
                </p>
              </div>

              <%= case @ollama_installed do %>
                <% {:error, reason} -> %>
                  <p class="text-xs text-red-600">
                    Ollama に接続できません: {inspect(reason)}
                  </p>
                <% _ -> %>
              <% end %>

              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs text-zinc-600 dark:text-zinc-400">
                  <thead class="text-[11px] text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                    <tr>
                      <th class="py-2 px-2">用途</th>
                      <th class="py-2 px-2">モデル</th>
                      <th class="py-2 px-2">状態</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-200/60 dark:divide-zinc-800">
                    <tr
                      :for={{{role, model}, i} <- Enum.with_index(@ollama_required)}
                      id={"required-model-#{i}"}
                      data-model={model}
                    >
                      <td class="py-2 px-2 whitespace-nowrap">{role}</td>
                      <td class="py-2 px-2 font-mono">{model}</td>
                      <td class="py-2 px-2">
                        <% pull = Map.get(@ollama_pulls, model) %>
                        <%= cond do %>
                          <% pull && pull.status in ["starting", "pulling"] -> %>
                            <span class="text-blue-600">
                              取得中{if p = pull_percent(pull), do: " #{p}%"}
                            </span>
                          <% model_installed?(@ollama_installed, model) -> %>
                            <span class="text-emerald-600">取得済み</span>
                          <% pull && pull.status == "failed" -> %>
                            <span class="text-red-600">取得失敗: {pull.error}</span>
                            <button
                              type="button"
                              phx-click="pull_model"
                              phx-value-model={model}
                              class="ml-2 underline text-indigo-600"
                            >
                              再試行
                            </button>
                          <% true -> %>
                            <span class="text-amber-600">未取得</span>
                            <button
                              type="button"
                              phx-click="pull_model"
                              phx-value-model={model}
                              class="ml-2 underline text-indigo-600"
                            >
                              取得
                            </button>
                        <% end %>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <form
                id="pull-model-form"
                phx-submit="pull_model"
                class="flex flex-wrap items-center gap-2"
              >
                <input
                  type="text"
                  name="model"
                  placeholder="例: qwen3:4b-instruct-2507-q4_K_M"
                  class="flex-1 min-w-[16rem] px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-xs font-mono"
                />
                <button
                  type="submit"
                  class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium"
                >
                  モデルを取得
                </button>
              </form>

              <div
                :for={{model, pull} <- @ollama_pulls}
                :if={
                  pull.status in ["starting", "pulling"] and
                    model not in Enum.map(@ollama_required, &elem(&1, 1))
                }
                class="text-xs text-blue-600"
              >
                {model}: 取得中{if p = pull_percent(pull), do: " #{p}%"}
              </div>

              <details :if={match?({:ok, _}, @ollama_installed)} class="text-xs">
                <summary class="cursor-pointer text-zinc-500">
                  取得済みのモデル（{length(elem(@ollama_installed, 1))} 件）
                </summary>
                <ul class="mt-1 font-mono text-[11px] text-zinc-600 dark:text-zinc-400 space-y-0.5">
                  <li :for={name <- elem(@ollama_installed, 1)}>{name}</li>
                </ul>
              </details>
            </div>

            <%!-- HTTPS / SSL certificate (spec 6.10) --%>
            <div
              :if={@scope == :platform}
              id="ssl-settings"
              class="p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200/80 dark:border-zinc-800 shadow-sm space-y-4"
            >
              <div>
                <h2 class="font-bold text-base text-zinc-900 dark:text-zinc-100 flex items-center gap-2">
                  <.icon name="hero-lock-closed" class="w-5 h-5 text-indigo-600" /> HTTPS（SSL 証明書）
                </h2>
                <p class="text-xs text-zinc-500 mt-1 leading-relaxed">
                  通信は HTTPS（ポート {AskDrive.SSL.https_port()}）で暗号化されます。HTTP（ポート {AskDrive.SSL.http_port()}）へのアクセスは HTTPS に転送されます（下の「ポートとリバースプロキシ」で指定したプロキシからは、HTTP のまま受け付けます）。
                </p>
              </div>

              <%= if AskDrive.SSL.enabled?() do %>
                <% cert = AskDrive.SSL.current() || %{} %>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs">
                  <div>
                    <span class="text-zinc-400 block">使用中の証明書</span>
                    <span class="font-medium text-zinc-800 dark:text-zinc-200">
                      {case cert["source"] do
                        "custom" -> "独自の証明書"
                        "self_signed" -> "自己署名証明書（ブラウザに警告が出ます）"
                        _ -> "不明"
                      end}
                    </span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">有効期限</span>
                    <span class="font-mono">{format_cert_time(cert["not_after"])}</span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">サブジェクト / 発行者</span>
                    <span class="font-mono break-all">{cert["subject"]} / {cert["issuer"]}</span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">対象のホスト名</span>
                    <span class="font-mono break-all">{Enum.join(cert["names"] || [], ", ")}</span>
                  </div>
                  <div>
                    <span class="text-zinc-400 block">HSTS</span>
                    <span>{if AskDrive.SSL.hsts?(), do: "有効（独自の証明書のため）", else: "無効（自己署名証明書の間は送りません）"}</span>
                  </div>
                </div>

                <p class="text-[11px] text-amber-700 dark:text-amber-300 bg-amber-50 dark:bg-amber-950/40 border border-amber-200 dark:border-amber-900 rounded-lg px-3 py-2">
                  管理画面が認証なしで開放されている間（POC）は、LAN 内の誰でも証明書を差し替えられます。外部公開の前に認証を有効にしてください。
                </p>

                <form
                  id="ssl-upload-form"
                  phx-submit="check_ssl"
                  phx-change="ssl_upload_change"
                  class="space-y-3"
                >
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
                    <label class="space-y-1">
                      <span class="block font-medium">証明書（PEM・必須）</span>
                      <.live_file_input upload={@uploads.ssl_cert} class={ssl_file_input_class()} />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">秘密鍵（PEM・必須）</span>
                      <.live_file_input upload={@uploads.ssl_key} class={ssl_file_input_class()} />
                    </label>
                    <label class="space-y-1">
                      <span class="block font-medium">中間証明書（PEM・任意）</span>
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
                    <span class="block font-medium">公開するホスト名（任意。指定すると証明書に含まれているか検証します）</span>
                    <input
                      type="text"
                      name="ssl_hostname"
                      placeholder="例: askdrive.example.com"
                      class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 font-mono"
                    />
                  </label>
                  <div class="flex flex-wrap gap-2">
                    <button
                      type="submit"
                      id="check-ssl-btn"
                      class="px-4 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-xs font-medium"
                    >
                      検証する
                    </button>
                    <button
                      :if={AskDrive.SSL.current()["source"] != "self_signed"}
                      type="button"
                      id="reset-self-signed-btn"
                      phx-click="reset_self_signed"
                      data-confirm="独自の証明書をやめ、自己署名証明書に戻します。ブラウザに証明書の警告が出るようになります。続行しますか？"
                      class="px-4 py-2 rounded-lg text-xs text-zinc-500 underline"
                    >
                      自己署名証明書に戻す
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
                        検証に成功しました（証明書と鍵の対応・有効期限・中間証明書・TLS 接続テスト）。
                      </p>
                      <p class="font-mono break-all">{info["subject"]}（発行者: {info["issuer"]}）</p>
                      <p class="font-mono break-all">ホスト名: {Enum.join(info["names"], ", ")}</p>
                      <p class="font-mono">有効期限: {format_cert_time(info["not_after"])}</p>
                      <button
                        type="button"
                        id="apply-ssl-btn"
                        phx-click="apply_ssl"
                        data-confirm="この証明書を保存し、HTTPS を再起動します。接続が数秒途切れます。続行しますか？"
                        class="mt-1 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium"
                      >
                        保存して適用（HTTPS を再起動）
                      </button>
                    </div>
                  <% {:error, errors} -> %>
                    <div
                      id="ssl-check-error"
                      class="text-xs rounded-lg border border-red-200 bg-red-50 dark:bg-red-950/40 dark:border-red-900 px-3 py-2 space-y-1 text-red-700 dark:text-red-300"
                    >
                      <p class="font-medium">検証に失敗しました。証明書は保存していません。</p>
                      <p :for={e <- errors}>・{e}</p>
                    </div>
                  <% _ -> %>
                <% end %>

                <p :if={msg = last_ssl_result()} class="text-xs text-red-600">{msg}</p>
              <% else %>
                <p class="text-xs text-zinc-500">
                  HTTPS は無効です（ASK_DRIVE_SSL=false）。HTTP で待ち受けています。
                </p>
              <% end %>

              <%!-- Ports and trusted reverse proxies (spec F-1013) --%>
              <% net = AskDrive.Network.settings() %>
              <div
                id="network-settings"
                class="pt-4 border-t border-zinc-200/60 dark:border-zinc-800 space-y-3"
              >
                <h3 class="font-semibold text-sm text-zinc-800 dark:text-zinc-200">
                  ポートとリバースプロキシ
                </h3>
                <p class="text-xs text-zinc-500 leading-relaxed">
                  前段のリバースプロキシで HTTPS を終端する場合は、そのプロキシの IP を指定してください。指定した IP からの HTTP は転送せずに受け付け、プロキシが付ける X-Forwarded-For / X-Forwarded-Proto / X-Forwarded-Host（Cloudflare の CF-Connecting-IP）を信頼します（利用者の実際の IP をロックや記録に使います）。それ以外からの HTTP は HTTPS に転送します。判定は接続元の IP で行い、ヘッダーは信頼しません。HSTS はプロキシ側で付けてください。
                </p>
                <p class="text-xs text-zinc-600 dark:text-zinc-400">
                  この画面の接続元: <span id="peer-ip" class="font-mono">{@peer_ip || "不明"}</span>
                  <span
                    :if={@peer_ip && AskDrive.Network.trusted?(parse_ip(@peer_ip))}
                    class="text-emerald-700"
                  >
                    （信頼するプロキシに含まれています）
                  </span>
                </p>
                <form id="network-form" phx-submit="save_network" class="space-y-3">
                  <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 text-xs">
                    <label class="space-y-1">
                      <span class="block font-medium">HTTPS のポート</span>
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
                      <span class="block font-medium">HTTP のポート</span>
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
                        HTTP を受け付けるプロキシの IP（複数可・カンマ区切り、範囲は 10.0.0.0/24 の形。空欄なら無効）
                      </span>
                      <input
                        type="text"
                        name="network[trusted_proxies]"
                        value={Enum.join(net.trusted_proxies, ", ")}
                        placeholder="例: 127.0.0.1, 192.168.1.10"
                        class="w-full px-3 py-2 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 font-mono"
                      />
                    </label>
                  </div>
                  <p class="text-[11px] text-zinc-400">
                    ポートを変更すると AskDrive の待ち受けを再起動します（数秒）。新しいポートで起動できなければ元に戻します。締め出された場合はサーバー上で
                    <code class="font-mono">./app.sh network ports-reset</code>
                    / <code class="font-mono">./app.sh network proxy-off</code>
                    で戻せます。プロキシ（Cloudflare Tunnel 等）の中継先ポートも合わせて変更してください。
                  </p>
                  <div class="flex justify-end">
                    <button
                      type="submit"
                      id="save-network-btn"
                      data-confirm="ポート・プロキシの設定を保存しますか？ポートを変えた場合は、新しいポートの URL で開き直す必要があります。"
                      class="px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-medium text-xs shadow-sm transition"
                    >
                      保存
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
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # A token alone proves only that Google accepted the key (and the delegation). What sync
  # actually needs is read access to the folder, which is exactly what failed with a bare
  # 404 when an org-only shared drive refused the service account — so check that too.
  defp check_drive_folder(%{drive_folder_id: folder_id}) when folder_id in [nil, ""] do
    {:ok, "トークンの取得に成功しました（#{Accounts.drive_identity()}）。同期フォルダが未設定のため、フォルダの読み取りは確認していません。"}
  end

  defp check_drive_folder(%{drive_folder_id: folder_id} = setting) do
    case Client.get_metadata(folder_id) do
      {:ok, folder} ->
        {:ok, "接続に成功しました（#{Accounts.drive_identity()}）。同期フォルダ「#{folder["name"]}」を読み取れます。"}

      {:error, "HTTP 404" <> _} ->
        {:error, folder_not_found_hint(setting)}

      {:error, reason} ->
        {:error, "トークンは取得できましたが、同期フォルダを読み取れませんでした: #{inspect(reason)}"}
    end
  end

  defp folder_not_found_hint(%{drive_impersonate_email: subject})
       when is_binary(subject) and subject != "" do
    "トークンは取得できましたが、#{subject} には同期フォルダの閲覧権限がありません。そのユーザーにフォルダ（または共有ドライブ）へのアクセス権を付与してください。"
  end

  defp folder_not_found_hint(_setting) do
    "トークンは取得できましたが、同期フォルダを読み取れません（Drive は権限のないファイルを「見つからない」と返します）。" <>
      "フォルダをサービスアカウントに共有してください。社内限定の共有ドライブでサービスアカウントを追加できない場合は、" <>
      "下の「なりすますユーザー」を設定してドメイン全体の委任を使ってください。"
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

  defp phase_label("sync"), do: "同期"
  defp phase_label("embed_chunks"), do: "取り込み"
  defp phase_label("generate"), do: "生成"
  defp phase_label(other), do: other

  defp item_status_label("created"), do: "新規"
  defp item_status_label("updated"), do: "更新"
  defp item_status_label("unchanged"), do: "変更なし"
  defp item_status_label("deleted"), do: "削除"
  defp item_status_label("indexed"), do: "取り込み完了"
  defp item_status_label("empty"), do: "本文なし"
  defp item_status_label("skipped"), do: "対象外"
  defp item_status_label("failed"), do: "失敗"
  defp item_status_label(other), do: other

  defp item_status_class("failed"),
    do: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"

  defp item_status_class(status) when status in ["indexed", "created", "updated"],
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

  defp item_status_class(status) when status in ["empty", "skipped", "deleted"],
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

  defp item_status_class(_), do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

  defp status_label("completed"), do: "完了"
  defp status_label("running"), do: "実行中"
  defp status_label("aborted"), do: "中断（再起動）"
  defp status_label("failed"), do: "失敗"
  defp status_label("deadline_reached"), do: "時間切れ"
  defp status_label("stopped"), do: "停止（手動）"
  defp status_label(other), do: other

  defp status_class("completed"),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"

  defp status_class("running"),
    do: "bg-blue-50 text-blue-700 dark:bg-blue-950/50 dark:text-blue-300 animate-pulse"

  defp status_class("deadline_reached"),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/50 dark:text-amber-300"

  defp status_class("stopped"),
    do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

  defp status_class(_), do: "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-300"

  defp trigger_label("auto"), do: "自動"
  defp trigger_label(_), do: "手動"

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # An aborted run's finished_at is when the next boot noticed it, not when it stopped.
  defp duration_label(%{status: "aborted"}), do: "—（中断）"

  defp duration_label(%{started_at: s, finished_at: nil}) when not is_nil(s) do
    "#{format_seconds(DateTime.diff(DateTime.utc_now(), s))}〜"
  end

  defp duration_label(%{started_at: s, finished_at: f}) when not is_nil(s) and not is_nil(f),
    do: format_seconds(DateTime.diff(f, s))

  defp duration_label(_), do: "—"

  # the newest run ended before finishing, and a re-run has something to do
  defp resumable?([%{status: status} | _], remaining)
       when status in ["failed", "stopped", "aborted", "deadline_reached"],
       do: remaining.documents + remaining.chunks + remaining.questions > 0

  defp resumable?(_runs, _remaining), do: false

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
      emails == [] -> {:error, "管理者のメールアドレスを入力してください。"}
      bad != [] -> {:error, "メールアドレスとして読み取れません: #{Enum.join(bad, "、")}"}
      outside != [] -> {:error, "@#{domain} 以外のアドレスは指定できません: #{Enum.join(outside, "、")}"}
      true -> {:ok, emails}
    end
  end

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
  defp autofill_ldap(%{"ldap_enabled" => "true"} = form, setting) do
    fill = fn form, key, value ->
      if String.trim(form[key] || "") == "" and value, do: Map.put(form, key, value), else: form
    end

    form
    |> fill.("ldap_host", AskDrive.Ldap.default_host())
    |> fill.("ldap_port", to_string(AskDrive.Ldap.default_port()))
    |> fill.("ldap_base_dn", AskDrive.Ldap.domain_base_dn(setting.allowed_domain))
  end

  defp autofill_ldap(form, _setting), do: form

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

  defp changeset_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Map.values()
    |> List.flatten()
    |> Enum.join("／")
  end

  defp eta_label(sec) when sec < 60, do: "1 分未満"
  defp eta_label(sec) when sec < 3600, do: "約 #{div(sec + 59, 60)} 分"
  defp eta_label(sec), do: "約 #{div(sec, 3600)} 時間 #{div(rem(sec, 3600), 60)} 分"

  # Progress.overview plus, while generating, whether the pace reaches the cut-off time
  defp progress_view(run) do
    now = DateTime.utc_now()

    case Progress.overview(run, now) do
      %{phase: "generate", eta_seconds: eta} = view
      when is_integer(eta) and run.status == "running" ->
        deadline = Scheduler.calculate_deadline(Settings.platform_setting!())

        if DateTime.compare(DateTime.add(now, eta), deadline) == :gt,
          do: Map.put(view, :past_deadline, AskDrive.Clock.format(deadline, "%H:%M")),
          else: view

      view ->
        view
    end
  end

  defp format_seconds(sec) when sec < 60, do: "#{sec}秒"
  defp format_seconds(sec) when sec < 3600, do: "#{div(sec, 60)}分#{rem(sec, 60)}秒"
  defp format_seconds(sec), do: "#{div(sec, 3600)}時間#{div(rem(sec, 3600), 60)}分"

  # Installed / required Ollama models and download progress for the settings screen.
  defp assign_ollama_models(socket) do
    alias AskDrive.LLM.OllamaModels

    setting = socket.assigns[:setting] || Settings.get_setting!()
    installed = OllamaModels.installed(setting)

    # the platform screen covers every app's models (one Ollama for all, spec 6.11)
    required =
      if socket.assigns[:scope] == :platform,
        do:
          Enum.map(OllamaModels.required_all(), fn {app, role, model} ->
            {"#{app.name}: #{role}", model}
          end),
        else: OllamaModels.required(setting)

    socket
    |> assign(:ollama_installed, installed)
    |> assign(:ollama_required, required)
    |> assign(:ollama_pulls, OllamaModels.pulls())
  end

  defp model_installed?({:ok, names}, model),
    do: AskDrive.LLM.OllamaModels.installed?(model, names)

  defp model_installed?(_, _), do: false

  defp pull_percent(%{completed: c, total: t}) when is_integer(t) and t > 0, do: div(c * 100, t)
  defp pull_percent(_), do: nil

  defp format_cert_time(nil), do: "—"

  defp format_cert_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> AskDrive.Clock.format(dt, "%Y-%m-%d %H:%M")
      _ -> iso
    end
  end

  defp upload_error_label(:too_large), do: "ファイルが大きすぎます"
  defp upload_error_label(:not_accepted), do: "PEM 形式（.pem / .crt / .cer / .key）のファイルを選んでください"
  defp upload_error_label(:too_many_files), do: "1 ファイルだけ選んでください"
  defp upload_error_label(other), do: inspect(other)

  # The page that clicked "apply" is gone after the endpoint restart; a failure (rolled back
  # to the previous certificate) is kept here so the reconnected page can show it.
  defp record_ssl_result(:ok), do: :persistent_term.erase({__MODULE__, :ssl_result})

  defp record_ssl_result({:error, message}),
    do: :persistent_term.put({__MODULE__, :ssl_result}, "前回の証明書の適用に失敗しました: #{message}")

  # the TCP peer of this admin's connection (to tell whether it came through a proxy)
  defp peer_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: ip} -> ip |> :inet.ntoa() |> to_string()
      _ -> nil
    end
  end

  defp parse_ip(nil), do: nil

  defp parse_ip(text) do
    case :inet.parse_address(String.to_charlist(text)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp last_ssl_result, do: :persistent_term.get({__MODULE__, :ssl_result}, nil)

  # Per-app figures for the platform's 窓口 tab
  defp app_summaries do
    AskDrive.Apps.each(fn _app ->
      last = Scheduler.list_runs(1) |> List.first()

      %{
        docs: Repo.aggregate(Document, :count, :id) || 0,
        chunks: Repo.aggregate(Chunk, :count, :id) || 0,
        drive?: Accounts.drive_connected?(),
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

  defp blank_app_form,
    do: to_form(AskDrive.Apps.App.changeset(%AskDrive.Apps.App{}, %{}), as: :app)

  defp slug_preview(form) do
    case form[:slug].value |> to_string() |> String.trim() |> String.downcase() do
      "" -> "（URL 名）"
      slug -> slug
    end
  end

  defp save_service_account(socket, attrs) do
    case Settings.update_setting(socket.assigns.setting, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:setting, updated)
         |> assign(:form, to_form(Settings.change_setting(updated)))
         |> assign(:service_account_test, nil)
         |> put_flash(:info, "サービスアカウントの認証情報を保存しました。")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(:error, "保存に失敗しました。JSON キーの内容を確認してください。")}
    end
  end
end
