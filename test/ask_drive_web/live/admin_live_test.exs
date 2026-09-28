defmodule AskDriveWeb.AdminLiveTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Documents.Document
  alias AskDrive.QA.QuestionLog
  alias AskDrive.Repo

  describe "AdminLive Dashboard" do
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

      {:ok, view, html} = live(conn, ~p"/admin")

      assert html =~ "管理ダッシュボード"
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

      {:ok, view, _html} = live(conn, ~p"/admin?tab=questions")
      html = render(view)

      assert html =~ "未回答質問"
      assert html =~ "育児休暇は何日間取得可能ですか？"

      # Switch to settings tab
      render_click(view, "select_tab", %{"tab" => "settings"})
      html = render(view)

      assert html =~ "システム・バッチ設定"
      assert html =~ "batch_model"
      assert html =~ "embed_model"
    end
  end
end
