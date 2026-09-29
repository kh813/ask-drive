defmodule AskDriveWeb.AdminLiveTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Documents.Document
  alias AskDrive.QA.QuestionLog
  alias AskDrive.Repo

  describe "AdminLive Dashboard" do
    setup %{conn: conn} do
      admin = user_fixture(admin_eligible: true)
      %{conn: log_in_admin(conn, admin)}
    end

    test "renders dashboard, tabs, and document list", %{conn: conn} do
      {:ok, _doc} =
        %Document{}
        |> Document.changeset(%{
          drive_file_id: "admin_test_doc",
          name: "就業規則.pdf",
          mime_type: "application/pdf",
          status: "indexed"
        })
        |> Repo.insert()

      {:ok, view, html} = live(conn, ~p"/it-support/admin")

      assert html =~ "管理: AskDrive for IT-Support"
      assert html =~ "概要・バッチ状況"
      assert html =~ "未回答・解消質問"
      assert html =~ "ドキュメント一覧"
      assert html =~ "設定"

      # Click Documents tab
      render_click(view, "select_tab", %{"tab" => "documents"})
      html = render(view)
      assert html =~ "就業規則.pdf"
      assert html =~ "application/pdf"
    end

    test "renders unanswered questions and settings tab", %{conn: conn} do
      {:ok, _log} =
        %QuestionLog{}
        |> QuestionLog.changeset(%{
          question: "育児休暇は何日間取得可能ですか？",
          tier_reached: 3,
          asked_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/it-support/admin?tab=questions")
      html = render(view)

      assert html =~ "未回答質問"
      assert html =~ "育児休暇は何日間取得可能ですか？"

      # Switch to settings tab
      render_click(view, "select_tab", %{"tab" => "settings"})
      html = render(view)

      assert html =~ "夜間バッチ（QA 生成）の実行方法"
      assert html =~ "Google Gemini API キー"
      assert html =~ "プロバイダ接続情報"
    end

    test "app-level admin access restriction", %{conn: _conn} do
      # Create normal user assigned only to hr app
      app_user = user_fixture(email: "hr_admin@example.com", admin_eligible: false)
      {:ok, _} = AskDrive.Accounts.add_app_admin(app_user, "hr")

      # Create an app for hr
      {:ok, _app} = AskDrive.Apps.create(%{slug: "hr", name: "人事部窓口"})

      conn = Phoenix.ConnTest.build_conn()
      app_admin_conn = log_in_admin(conn, app_user)

      # Allowed to access /hr/admin
      {:ok, _view, html} = live(app_admin_conn, "/hr/admin")
      assert html =~ "管理: AskDrive for 人事部窓口"

      # Not allowed to access /admin (redirects to / because user is not super admin)
      assert {:error, {:redirect, %{to: "/"}}} = live(app_admin_conn, "/admin")
    end

    test "app admin password change and access password setting", %{conn: conn} do
      {:ok, _} = AskDrive.Accounts.AdminAccess.force_set_password("password12345")
      {:ok, view, _html} = live(conn, ~p"/it-support/admin?tab=settings")

      # Change app admin password
      html =
        view
        |> form("#app-admin-password-form", %{
          "admin_password" => %{
            "current" => "password12345",
            "new" => "newapppwd888",
            "confirmation" => "newapppwd888"
          }
        })
        |> render_submit()

      assert html =~ "管理者パスワードを変更しました。"

      # Set access password
      html =
        view
        |> form("#access-password-form", %{
          "access_password" => %{
            "enabled" => "true",
            "password" => "aikotoba123",
            "confirmation" => "aikotoba123"
          }
        })
        |> render_submit()

      assert html =~ "窓口アクセスパスワード（合言葉）を設定しました。"
      assert html =~ "利用制限: 有効"

      # Disable access password
      html =
        view
        |> element("#disable-access-password-btn")
        |> render_click()

      assert html =~ "窓口アクセスパスワード（合言葉）を無効化しました。"
      assert html =~ "利用制限: 無効"
    end

    test "super admin resets app admin password from /admin", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin?tab=apps")
      assert html =~ "管理者PW再設定"

      # Click toggle reset
      app = AskDrive.Apps.get_by_slug!("it-support")

      view
      |> element(
        "button[phx-click='toggle_reset_app_password'][phx-value-app_slug='#{app.slug}']"
      )
      |> render_click()

      # Submit reset password form
      html =
        view
        |> form("form[phx-submit='reset_app_admin_password']", %{
          "app_slug" => app.slug,
          "new_password" => "resetpwd9999",
          "confirmation" => "resetpwd9999"
        })
        |> render_submit()

      assert html =~ "窓口「#{app.name}」の管理者パスワードを再設定しました。"
    end

    test "renders API usage and logs tab", %{conn: conn} do
      AskDrive.Metrics.record(%{
        provider: "gemini",
        model: "gemini-2.5-flash",
        purpose: "chat_summary",
        prompt_tokens: 100,
        completion_tokens: 50,
        total_tokens: 150,
        request_bytes: 450,
        latency_ms: 220,
        status: "ok"
      })

      Process.sleep(50)

      {:ok, _view, html} = live(conn, ~p"/it-support/admin?tab=metrics")
      assert html =~ "API利用量・ログ"
      assert html =~ "総リクエスト数"
      assert html =~ "総消費トークン数"
      assert html =~ "平均応答時間"
      assert html =~ "gemini-2.5-flash"
    end
  end
end
