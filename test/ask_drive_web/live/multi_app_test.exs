defmodule AskDriveWeb.MultiAppTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AskDrive.AppsHelper
  import Ecto.Query

  alias AskDrive.{Apps, Repo}
  alias AskDrive.Batch.BatchRun
  alias AskDrive.Documents.{Chunk, Document}

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
    %{hr: create_app!("hr", "HR")}
  end

  defp add_doc!(app, name, text) do
    Apps.with_app(app, fn ->
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          drive_file_id: name,
          name: name,
          mime_type: "text/plain",
          status: "indexed"
        })
        |> Repo.insert()

      %Chunk{}
      |> Chunk.changeset(%{document_id: doc.id, position: 0, content_hash: name, content: text})
      |> Repo.insert!()
    end)
  end

  test "the portal lists every app with its URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#app-card-it-support", "AskDrive for IT-Support")
    assert has_element?(view, "#app-card-hr", "AskDrive for HR")
  end

  test "each app's chat answers only from its own documents", %{conn: conn, hr: hr} do
    add_doc!(hr, "就業規則", "有給休暇は入社6か月後に10日付与する。")
    add_doc!(Apps.primary(), "USB規程", "USBメモリは会社貸与品のみ利用できる。")

    {:ok, _} =
      Apps.with_app(hr, fn ->
        AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
          chat_summary_enabled: false
        })
      end)

    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        chat_summary_enabled: false
      })

    {:ok, view, html} = live(conn, "/hr")
    assert html =~ "for HR"
    view |> form("#chat-form", %{"question" => "有給休暇は何日？"}) |> render_submit()
    html = render_async(view, 20_000)
    assert html =~ "就業規則"
    refute html =~ "USB規程"

    {:ok, view, _html} = live(conn, "/it-support")
    view |> form("#chat-form", %{"question" => "有給休暇は何日？"}) |> render_submit()
    html = render_async(view, 20_000)
    refute html =~ "就業規則"
  end

  test "the chat header offers the other apps", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/hr")
    assert has_element?(view, "#app-switcher a[href='/it-support']", "AskDrive for IT-Support")
  end

  test "platform admin creates an app; its admin page shows only app settings", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin")
    assert html =~ "全体管理"
    assert has_element?(view, "#app-row-hr")
    assert has_element?(view, "#admin-scope-label", "すべての窓口に適用")
    # Platform Admin sits in the admin-mode group on the right, marked as the current page
    assert has_element?(view, "#admin-mode-group #platform-admin-nav-link[aria-current='page']")
    assert has_element?(view, "#admin-mode-group #release-admin-link")

    # the add form opens right above the list
    refute has_element?(view, "#new-app-form")
    view |> element("#show-new-app-btn") |> render_click()
    assert has_element?(view, "#new-app-form")

    # live validation: a taken slug and a reserved one, and the URL preview
    html = view |> form("#new-app-form", app: %{name: "X", slug: "hr"}) |> render_change()
    assert html =~ "は既に使われています"
    html = view |> form("#new-app-form", app: %{name: "X", slug: "admin"}) |> render_change()
    assert html =~ "システムで使用するため"
    view |> form("#new-app-form", app: %{name: "Legal", slug: "legal"}) |> render_change()
    assert has_element?(view, "#new-app-url", "/legal")

    # the administrator's e-mail is required (F-1114)
    view
    |> form("#new-app-form", app: %{name: "Legal", slug: "legal", admin_emails: ""})
    |> render_submit()

    assert render(view) =~ "担当者: 管理者のメールアドレスを入力してください"
    refute Apps.get_by_slug("legal")

    view
    |> form("#new-app-form",
      app: %{
        name: "Legal",
        slug: "legal",
        description: "法務の相談窓口",
        admin_emails: "legal-owner@example.com"
      }
    )
    |> render_submit()

    assert has_element?(view, "#app-row-legal")
    refute has_element?(view, "#new-app-form")
    assert has_element?(view, "#open-new-app-settings[href='/legal/admin?tab=settings']")
    legal = Apps.get_by_slug("legal")
    on_exit(fn -> Apps.Repos.stop_app_repo("legal") end)
    assert File.exists?(legal.db_path)

    {:ok, legal_view, html} = live(conn, "/legal/admin?tab=settings")
    assert html =~ "Legal の管理"
    assert has_element?(legal_view, "#admin-scope-label", "この窓口だけに適用")
    assert has_element?(legal_view, "#admin-nav-link[aria-current='page']", "Manage Legal")
    refute has_element?(legal_view, "#platform-admin-nav-link[aria-current]")
    assert html =~ "Google Drive"
    assert html =~ "窓口管理者"
    assert html =~ "legal-owner@example.com"
    refute html =~ "HTTPS（SSL 証明書）"
    refute html =~ "Google Secure LDAP でのログイン"

    {:ok, _view, html} = live(conn, ~p"/admin?tab=settings")
    assert html =~ "HTTPS（SSL 証明書）"
    refute html =~ "サービスアカウントの JSON キー"
  end

  test "an app's manual batch is recorded in that app only", %{conn: conn, hr: hr} do
    {:ok, view, _html} = live(conn, "/hr/admin")
    view |> element("#trigger-ingest-btn") |> render_click()

    run =
      Enum.find_value(1..50, fn _ ->
        Process.sleep(100)
        Apps.with_app(hr, fn -> Repo.one(from b in BatchRun, limit: 1) end)
      end)

    assert run.kind == "ingest_only"
    refute Repo.exists?(BatchRun)

    Enum.find_value(1..50, fn _ ->
      Process.sleep(100)
      Apps.with_app(hr, fn -> Repo.get(BatchRun, run.id).status != "running" end)
    end)
  end

  test "requests always start (and end) in the platform database", %{hr: hr} do
    Apps.put_current(hr)
    conn = Phoenix.ConnTest.build_conn() |> AskDriveWeb.Plugs.ResetApp.call([])
    assert Repo.get_dynamic_repo() == Repo
    assert Apps.current() == nil
    assert conn.private[:before_send] != []
  end

  test "the platform settings put the Workspace domain in its own card; apps don't show it", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")
    assert has_element?(view, "#org-settings input[name='setting[allowed_domain]']")

    view |> form("#org-form", setting: %{allowed_domain: "Example.com"}) |> render_submit()
    assert AskDrive.Settings.get_setting!().allowed_domain == "example.com"

    {:ok, view, _html} = live(conn, "/hr/admin?tab=settings")
    refute has_element?(view, "#org-settings")
  end

  test "a delegation user outside the organization's domain is refused", %{conn: conn, hr: hr} do
    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        allowed_domain: "example.com"
      })

    {:ok, view, _html} = live(conn, "/hr/admin?tab=settings")
    view |> element("button[phx-value-mode='service_account']") |> render_click()

    html =
      view
      |> form("#service-account-form",
        setting: %{drive_service_account_json: "", drive_impersonate_email: "sync@other.org"}
      )
      |> render_submit()

    assert html =~ "組織のドメイン（@example.com）"

    assert Apps.with_app(hr, fn -> AskDrive.Settings.get_setting!().drive_impersonate_email end) ==
             nil
  end
end
