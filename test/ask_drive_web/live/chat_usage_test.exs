defmodule AskDriveWeb.ChatUsageTest do
  @moduledoc """
  A question asked on the chat screen is recorded for the 「利用状況」 tab (F-1415): who asked,
  with the tokens its search and its AI summary used, never what was asked.
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias AskDrive.Metrics.ApiUsageLog
  alias AskDrive.Repo
  alias AskDrive.Usage.QuestionUsage

  setup %{conn: conn} do
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
        drive_file_id: "usage_doc",
        name: "guide.pdf",
        mime_type: "application/pdf",
        status: "indexed"
      })
      |> Repo.insert()

    {:ok, _} =
      %AskDrive.Documents.Chunk{}
      |> AskDrive.Documents.Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        content_hash: "u",
        content: "USB メモリ、外付け HDD も接続を禁止する。",
        page: 5
      })
      |> Repo.insert()

    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "a question records its asker and the tokens of the search and the AI summary", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/it-support")
    view |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"}) |> render_submit()

    # the answer, then the summary
    render_async(view, 20_000)
    html = render_async(view, 20_000)
    assert html =~ "外部記憶媒体の接続は禁止されています"

    assert [usage] = Repo.all(QuestionUsage)
    assert usage.user_id == user.id
    assert usage.tier == 2
    refute usage.follow_up
    assert usage.question_log_id

    # every API call answering it: the query embedding and the summary
    purposes = Repo.all(from l in ApiUsageLog, select: l.purpose)
    assert length(purposes) >= 2
    assert usage.tokens > 0
    assert usage.tokens == Repo.one(from l in ApiUsageLog, select: sum(l.total_tokens))
  end

  test "the row holds no question text", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/it-support")
    view |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"}) |> render_submit()
    render_async(view, 20_000)

    [usage] = Repo.all(QuestionUsage)
    refute inspect(Map.from_struct(usage)) =~ "USB"
  end
end
