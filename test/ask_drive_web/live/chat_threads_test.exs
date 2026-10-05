defmodule AskDriveWeb.ChatThreadsTest do
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

  defp follow_up(view, thread, question) do
    view |> element("#followup-btn-#{thread}") |> render_click()
    assert has_element?(view, "#followup-form-#{thread}")

    view
    |> form("#followup-form-#{thread}", %{"followup" => %{"question" => question}})
    |> render_submit()

    render_async(view, 20_000)
  end

  defp threads(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-thread]")
    |> LazyHTML.attribute("data-thread")
  end

  test "a new question is a thread of its own; a follow-up joins its answer's thread (F-431)", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/it-support")
    refute has_element?(view, "#new-question-hint")

    ask(view, "有給休暇は何日？")
    [first] = threads(view)
    assert has_element?(view, "#new-question-hint")

    follow_up(view, first, "申請は何日前まで？")
    # still one thread, with both questions, the follow-up marked
    assert threads(view) == [first]
    assert has_element?(view, "#thread-#{first} [data-role='user']", "有給休暇は何日？")
    assert has_element?(view, "#thread-#{first} [data-role='user']", "申請は何日前まで？")
    assert has_element?(view, "#thread-#{first} [data-role='user']", "Follow-up")

    # the bottom input starts another thread
    ask(view, "VPN の接続方法は？")
    assert [^first, second] = threads(view)
    assert second != first

    # a follow-up to the first thread goes into it, not to the end
    follow_up(view, first, "半休は？")
    assert threads(view) == [first, second]
    assert has_element?(view, "#thread-#{first} [data-role='user']", "半休は？")
    # and it is the question the screen scrolls to
    latest =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#chat-messages")
      |> LazyHTML.attribute("data-latest")
      |> hd()

    assert has_element?(view, "#msg-#{latest}", "半休は？")

    # the history keeps threads: one entry each, with the follow-ups inside
    assert [%{id: ^first, title: "有給休暇は何日？", follow_ups: 2}, %{id: ^second, follow_ups: 0}] =
             ChatHistory.list(user) |> Enum.sort_by(&(&1.id != first))

    assert ["有給休暇は何日？", "申請は何日前まで？", "半休は？"] =
             ChatHistory.get_thread(user, first) |> Enum.map(& &1.question)
  end

  test "a thread from the history comes back whole, and a follow-up to it continues it", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/it-support")
    ask(view, "経費精算の締め日は？")
    [thread] = threads(view)
    follow_up(view, thread, "例外はある？")

    view |> element("#reset-chat-btn") |> render_click()
    view |> element("#history-btn") |> render_click()

    assert has_element?(view, "#history-list li", "1 follow-ups") or
             has_element?(view, "#history-list li", "追加の質問 1 件")

    view |> element("#history-open-#{thread}") |> render_click()
    assert threads(view) == [thread]
    assert has_element?(view, "#thread-#{thread} [data-role='user']", "例外はある？")

    follow_up(view, thread, "締め日が休日なら？")
    assert length(ChatHistory.get_thread(user, thread)) == 3

    # deleting it deletes every question in it
    view |> element("#history-btn") |> render_click()
    view |> element("#history-delete-#{thread}") |> render_click()
    assert ChatHistory.get_thread(user, thread) == []
  end

  test "a follow-up is searched with the thread's questions and summarised with its exchanges",
       %{conn: conn} do
    {server, url} = AskDrive.StubOllama.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)
    AskDrive.StubOllama.put_generate_pieces(["外部記憶媒体の接続は禁止されています [1]。"])

    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        ollama_host: url,
        llm_provider: "ollama",
        embed_provider: "ollama"
      })

    {:ok, doc} =
      %AskDrive.Documents.Document{}
      |> AskDrive.Documents.Document.changeset(%{
        drive_file_id: "thread_doc",
        name: "guide.pdf",
        mime_type: "application/pdf",
        status: "indexed"
      })
      |> AskDrive.Repo.insert()

    %AskDrive.Documents.Chunk{}
    |> AskDrive.Documents.Chunk.changeset(%{
      document_id: doc.id,
      position: 0,
      content_hash: "t",
      content: "USB メモリ、外付け HDD も接続を禁止する。",
      page: 5
    })
    |> AskDrive.Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/it-support")
    ask(view, "USBメモリの利用ルールは？")
    render_async(view, 20_000)
    assert_receive {:stub_generate, %{"prompt" => first_prompt}}, 5_000
    refute first_prompt =~ "これまでのやり取り"

    # (a summary may take two passes: let the first question's requests go)
    flush_generates()
    [thread] = threads(view)
    follow_up(view, thread, "それは外付けHDDも同じ？")
    render_async(view, 20_000)

    assert_receive {:stub_generate, %{"prompt" => prompt}}, 5_000
    assert prompt =~ "これまでのやり取り"
    assert prompt =~ "質問: USBメモリの利用ルールは？"
    assert prompt =~ "回答: 外部記憶媒体の接続は禁止されています"
    assert prompt =~ "質問: それは外付けHDDも同じ？"
  end

  defp flush_generates do
    receive do
      {:stub_generate, _} -> flush_generates()
    after
      0 -> :ok
    end
  end
end
