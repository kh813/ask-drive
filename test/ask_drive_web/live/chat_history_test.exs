defmodule AskDriveWeb.ChatHistoryTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.ChatHistory

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp ask(view, question) do
    view |> form("#chat-form", %{"question" => question}) |> render_submit()
    render_async(view, 20_000)
  end

  test "questions are kept per user: listed, searched, opened again and deleted (F-430)", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/it-support")
    ask(view, "経費精算の締め日は？")
    ask(view, "VPN の接続方法は？")

    assert [%{title: "VPN の接続方法は？"}, %{title: "経費精算の締め日は？"}] =
             ChatHistory.list(user)

    view |> element("#reset-chat-btn") |> render_click()
    view |> element("#history-btn") |> render_click()
    assert has_element?(view, "#history-panel")
    assert has_element?(view, "#history-list li", "経費精算の締め日は？")

    view |> form("#history-search-form", %{"q" => "VPN"}) |> render_change()
    assert has_element?(view, "#history-list li", "VPN の接続方法は？")
    refute has_element?(view, "#history-list li", "経費精算の締め日は？")

    [vpn] = ChatHistory.list(user, "VPN")
    view |> element("#history-open-#{vpn.id}") |> render_click()
    refute has_element?(view, "#history-panel")
    assert has_element?(view, "#chat-messages", "VPN の接続方法は？")

    view |> element("#history-btn") |> render_click()
    view |> element("#history-delete-#{vpn.id}") |> render_click()
    refute has_element?(view, "#history-open-#{vpn.id}")
    assert [%{title: "経費精算の締め日は？"}] = ChatHistory.list(user)
  end

  test "someone else's history is neither listed nor opened", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/it-support")
    ask(view, "私だけの質問")
    [entry] = ChatHistory.list(user)

    other = user_fixture()
    assert ChatHistory.list(other) == []
    assert ChatHistory.get_thread(other, entry.id) == []
    assert ChatHistory.delete_thread(other, entry.id) == {:error, :not_found}

    {:ok, view, _html} = live(log_in_user(build_conn(), other), ~p"/it-support")
    view |> element("#history-btn") |> render_click()
    refute has_element?(view, "#history-list li", "私だけの質問")
    render_click(view, "history_open", %{"id" => entry.id})
    refute has_element?(view, "#chat-messages", "私だけの質問")
  end

  test "the shared guest (login off) keeps no history" do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)

    {:ok, view, _html} = live(build_conn(), ~p"/it-support")
    refute has_element?(view, "#history-btn")
    ask(view, "ゲストの質問")
    assert AskDrive.Repo.aggregate(AskDrive.ChatHistory.Entry, :count) == 0
  end

  test "an answer whose excerpts were re-indexed since shows its summary and what the sources were",
       %{conn: conn, user: user} do
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
        drive_file_id: "hist_doc",
        name: "guide.pdf",
        mime_type: "application/pdf",
        status: "indexed",
        web_view_link: "https://drive.google.com/file/d/hist/view"
      })
      |> AskDrive.Repo.insert()

    {:ok, chunk} =
      %AskDrive.Documents.Chunk{}
      |> AskDrive.Documents.Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        content_hash: "h",
        content: "USB メモリ、外付け HDD も接続を禁止する。",
        page: 5
      })
      |> AskDrive.Repo.insert()

    {:ok, view, _html} = live(conn, ~p"/it-support")
    ask(view, "USBメモリの利用ルールは？")
    render_async(view, 20_000)

    [entry] = ChatHistory.list(user)
    assert entry.tier == 2
    [saved] = ChatHistory.get_thread(user, entry.id)
    assert saved.summary == "外部記憶媒体の接続は禁止されています [1]。"
    assert [%{"name" => "guide.pdf", "page" => 5}] = saved.sources

    # still there: opened with its excerpts
    view |> element("#reset-chat-btn") |> render_click()
    view |> element("#history-btn") |> render_click()
    view |> element("#history-open-#{entry.id}") |> render_click()
    assert has_element?(view, "#chat-messages", "USB メモリ")
    refute has_element?(view, "[id^='history-sources-']")

    # re-indexed: the excerpt is gone
    AskDrive.Repo.delete!(chunk)
    view |> element("#reset-chat-btn") |> render_click()
    view |> element("#history-btn") |> render_click()
    view |> element("#history-open-#{entry.id}") |> render_click()
    assert has_element?(view, "[id^='history-sources-']", "guide.pdf")
    assert has_element?(view, "[id^='history-sources-']", "外部記憶媒体の接続は禁止されています")
  end
end
