defmodule AskDriveWeb.AdminLiveTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Documents.Document
  alias AskDrive.QA.QuestionLog
  alias AskDrive.Repo

  describe "AdminLive Dashboard" do
    setup %{conn: conn} do
      # a platform admin who is also IT-Support's assigned administrator (F-1113)
      admin = user_fixture(admin_eligible: true)
      %{conn: conn |> log_in_admin(admin) |> log_in_app_admin(admin), admin: admin}
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

    test "an app admin gets into their app's admin screen only, not /admin", %{conn: _conn} do
      {:ok, _app} = AskDrive.Apps.create(%{slug: "hr", name: "人事部窓口"})
      app_user = user_fixture(email: "hr_admin@example.com", admin_eligible: false)

      conn = build_conn() |> log_in_user(app_user) |> log_in_app_admin(app_user, "hr")

      {:ok, _view, html} = live(conn, "/hr/admin")
      assert html =~ "管理: AskDrive for 人事部窓口"

      # not IT-Support's (not assigned), not the platform screen
      assert {:error, {:redirect, %{to: "/it-support"}}} = live(conn, "/it-support/admin")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin")
    end

    test "app admin password change (the app's own) and access password setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/it-support/admin?tab=settings")

      # Change the app's admin password: back to the elevation prompt with the new one
      assert {:error, {:redirect, %{to: "/it-support/admin/elevate"}}} =
               view
               |> form("#app-admin-password-form", %{
                 "admin_password" => %{
                   "current" => "app-pass-123",
                   "new" => "newapppwd888",
                   "confirmation" => "newapppwd888"
                 }
               })
               |> render_submit()

      app = AskDrive.Apps.get_by_slug!("it-support")

      admin =
        AskDrive.Accounts.get_user_by_email(
          conn
          |> Plug.Conn.get_session(:user_id)
          |> AskDrive.Accounts.get_user()
          |> Map.fetch!(:email)
        )

      assert {:ok, _} = AskDrive.Accounts.AppAdminAccess.elevate(admin, app, "newapppwd888")
      # the platform password is untouched and unrelated
      refute AskDrive.Accounts.AdminAccess.password_matches?(
               AskDrive.Settings.platform_setting!().admin_password_hash,
               "newapppwd888"
             )

      conn = log_in_app_admin(conn, admin, "it-support", "newapppwd888")
      {:ok, view, _html} = live(conn, ~p"/it-support/admin?tab=settings")

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

    test "a platform admin resets (clears) an app's password from /admin; it is recorded",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin?tab=apps")
      assert html =~ "管理者PW: 設定済み"

      view |> element("#reset-app-password-it-support") |> render_click()
      assert render(view) =~ "管理者パスワードをリセットしました"
      assert render(view) =~ "未設定（担当者が初回に設定）"

      app = AskDrive.Apps.get_by_slug!("it-support")
      refute AskDrive.Accounts.AppAdminAccess.password_set?(app)
      assert AskDrive.Accounts.AppAdminAccess.setting(app).app_admin_password_reset_at
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
      assert html =~ "インデックス対象データのトークン効率・構造化分析"
      assert html =~ "ファイル形式別のトークン効率比較"
    end
  end
end
