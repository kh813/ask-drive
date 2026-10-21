defmodule AskDriveWeb.ChatSolvedTest do
  @moduledoc "「解決した」 under an answer, and a follow-up marking it unresolved (F-433)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.QA.QuestionLog
  alias AskDrive.Repo

  setup %{conn: conn} do
    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        chat_summary_enabled: false
      })

    doc =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "solved_doc",
        name: "usb.pdf",
        mime_type: "application/pdf",
        status: "indexed"
      })
      |> Repo.insert!()

    %Chunk{}
    |> Chunk.changeset(%{
      document_id: doc.id,
      position: 0,
      content_hash: "c",
      content: "USB メモリの接続を禁止する。"
    })
    |> Repo.insert!()

    %{conn: log_in_user(conn, user_fixture())}
  end

  defp last_log, do: Repo.one(from q in QuestionLog, order_by: [desc: q.id], limit: 1)

  test "「解決した」 marks the question, pressed again takes it back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/it-support")
    view |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"}) |> render_submit()
    render_async(view, 20_000)

    assert has_element?(view, "[id^='solved-btn-'][aria-pressed='false']")
    view |> element("[id^='solved-btn-']") |> render_click()
    assert has_element?(view, "[id^='solved-btn-'][aria-pressed='true']")
    assert last_log().user_solved_at

    view |> element("[id^='solved-btn-']") |> render_click()
    refute last_log().user_solved_at
  end

  test "a follow-up marks the answer before it as not settled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/it-support")
    view |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"}) |> render_submit()
    render_async(view, 20_000)
    first = last_log()

    view |> element("[id^='followup-btn-']") |> render_click()

    view
    |> form("[id^='followup-form-']", followup: %{question: "外付けHDDは？"})
    |> render_submit()

    render_async(view, 20_000)

    assert Repo.get!(QuestionLog, first.id).followed_up_at
  end
end
