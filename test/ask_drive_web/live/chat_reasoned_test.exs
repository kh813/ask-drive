defmodule AskDriveWeb.ChatReasonedTest do
  @moduledoc """
  A reasoned answer (F-436) on the chat screen: the part of a document it cites beyond the
  excerpts is added to the sources shown, and kept in the history.
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{Repo, Settings, StubGemini}
  alias AskDrive.Documents.{Chunk, Document}

  setup %{conn: conn} do
    {server, url} = StubGemini.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{
        chat_summary_provider: "gemini",
        chat_summary_model: "gemini-2.5-flash",
        gemini_api_key: "k",
        gemini_base_url: url
      })

    doc =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "naming",
        name: "命名規則.pdf",
        mime_type: "application/pdf",
        status: "indexed"
      })
      |> Repo.insert!()

    contents = [
      "共有ドライブの命名規則: 共有ドライブ名は「SEng_部署名」の形式とする。",
      "第2条 部署の略称は組織表に従う。",
      "第3条 申請は総務部へ。",
      "第4条 改廃は情報システム部が行う。",
      "第5条 空白文字や記号は使わない（バックアップのスクリプトのため）。"
    ]

    for {content, i} <- Enum.with_index(contents) do
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: i,
        content: content,
        content_hash: "n#{i}"
      })
      |> Repo.insert!()
    end

    StubGemini.set(:generate_parts, [
      %{"text" => ~s({"mode": "reasoned", "intent": "名前が規則に合うか", "queries": []})}
    ])

    %{conn: log_in_user(conn, user_fixture())}
  end

  test "the rule it cites from further on in the document is shown as a source", %{conn: conn} do
    # the 5th article is the document's last part: whatever the excerpts are, it is the last
    # number the model is given, [5]
    StubGemini.set(:parts, [%{"text" => "沿っていません [1]。名前に空白を含みます [5]。"}])

    {:ok, view, _html} = live(conn, ~p"/it-support")

    view
    |> form("#chat-form", %{"question" => "この共有ドライブ名は命名規則に沿っていますか？ SEng_A B"})
    |> render_submit()

    render_async(view, 20_000)
    html = render_async(view, 20_000)

    # shown after the excerpts, as the next number, and cited as that
    shown =
      Regex.scan(~r/id="src-\d+-(\d+)"/, html) |> Enum.map(fn [_, n] -> n end) |> Enum.uniq()

    last = length(shown)
    assert html =~ "空白文字や記号は使わない"
    assert html =~ ~r{<a href="#src-\d+-#{last}"[^>]*>\[#{last}\]</a>}
    # renumbered: fewer than 5 parts shown, the 5th article among them
    assert last < 5

    [entry] = Repo.all(AskDrive.ChatHistory.Entry)
    assert length(entry.chunk_ids) == last
    assert entry.summary =~ "[#{last}]"
  end
end
