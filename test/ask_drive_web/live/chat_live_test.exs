defmodule AskDriveWeb.ChatLiveTest do
  use AskDriveWeb.ConnCase
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture())}
  end

  test "renders chat page and submits question", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "AskDrive"
    assert html =~ "chat-form"

    # Submit question
    html =
      view
      |> form("#chat-form", %{"question" => "社内規定について教えてください"})
      |> render_submit()

    assert html =~ "社内規定について教えてください"
  end

  test "answers asynchronously: question first, then the answer bubble", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"})
    |> render_submit()

    html = render_async(view, 20_000)
    assert html =~ "USBメモリの利用ルールは？"
    assert html =~ "未回答"
    refute has_element?(view, "#answer-loading")
  end

  test "Tier 2 excerpts highlight the question's terms", %{conn: conn} do
    # Summary off: this covers the excerpt-only view
    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        chat_summary_enabled: false
      })

    {:ok, doc} =
      %AskDrive.Documents.Document{}
      |> AskDrive.Documents.Document.changeset(%{
        drive_file_id: "chat_hl_doc",
        name: "sme_guideline.pdf",
        mime_type: "application/pdf",
        status: "indexed",
        web_view_link: "https://drive.google.com/file/d/abc/view?usp=drivesdk"
      })
      |> AskDrive.Repo.insert()

    {:ok, _} =
      %AskDrive.Documents.Chunk{}
      |> AskDrive.Documents.Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        content_hash: "c",
        content: "[文書: sme_guideline.pdf]\nじ じ\nメールやウェブ閲覧に利用せず、USB メモリ、外付け HDD も接続を禁止する。",
        page: 33
      })
      |> AskDrive.Repo.insert()

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"})
    |> render_submit()

    html = render_async(view, 20_000)
    assert html =~ "関連しそうな箇所"
    assert html =~ ~r{<mark[^>]*>USB メモリ</mark>}
    refute html =~ "じ じ"
    assert html =~ "p.33"
    assert html =~ "https://drive.google.com/file/d/abc/view?usp=drivesdk#page=33"
  end

  test "resets chat history", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#chat-form", %{"question" => "質問1"})
    |> render_submit()

    assert render(view) =~ "質問1"

    view
    |> element("#reset-chat-btn")
    |> render_click()

    refute render(view) =~ "質問1"
  end

  test "signed-out visitors can chat and see the admin login link" do
    {:ok, view, _html} = live(build_conn(), ~p"/")
    assert has_element?(view, "#chat-form")
    assert has_element?(view, "#admin-login-link")
    refute has_element?(view, "#logout-link")

    view
    |> form("#chat-form", %{"question" => "ゲストの質問"})
    |> render_submit()

    assert render(view) =~ "ゲストの質問"
  end

  test "Tier 2 shows a streamed AI summary whose citations link to the sources", %{conn: conn} do
    {server, url} = AskDrive.StubOllama.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)
    AskDrive.StubOllama.put_generate_pieces(["外部記憶媒体の接続は", "禁止されています [1]。"])

    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        ollama_host: url,
        llm_provider: "ollama",
        embed_provider: "ollama"
      })

    {:ok, doc} =
      %AskDrive.Documents.Document{}
      |> AskDrive.Documents.Document.changeset(%{
        drive_file_id: "sum_doc",
        name: "guide.pdf",
        mime_type: "application/pdf",
        status: "indexed"
      })
      |> AskDrive.Repo.insert()

    {:ok, _} =
      %AskDrive.Documents.Chunk{}
      |> AskDrive.Documents.Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        content_hash: "s",
        content: "USB メモリ、外付け HDD も接続を禁止する。",
        page: 5
      })
      |> AskDrive.Repo.insert()

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"})
    |> render_submit()

    render_async(view, 20_000)
    html = render_async(view, 20_000)

    assert html =~ "AI による要約"
    assert html =~ "外部記憶媒体の接続は禁止されています"
    assert html =~ ~r{<a href="#src-\d+-1"[^>]*>\[1\]</a>}
    assert html =~ ~r{id="src-\d+-1"}
  end
end
