defmodule AskDriveWeb.ChatRestyleTest do
  @moduledoc """
  「もっと詳しく」 / 「やさしく言い直す」 under an AI summary (F-438): the summary written
  again in that style from the same excerpts, below the desk's own answer.
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
        drive_file_id: "usb",
        name: "guide.pdf",
        mime_type: "application/pdf",
        status: "indexed"
      })
      |> Repo.insert!()

    %Chunk{}
    |> Chunk.changeset(%{
      document_id: doc.id,
      position: 0,
      content: "USB メモリ、外付け HDD も接続を禁止する。",
      content_hash: "u",
      page: 5
    })
    |> Repo.insert!()

    StubGemini.set(:generate_parts, [%{"text" => ~s({"mode": "direct"})}])
    StubGemini.set(:parts, [%{"text" => "接続は禁止です [1]。"}])

    %{conn: log_in_user(conn, user_fixture())}
  end

  defp ask(conn) do
    {:ok, view, _html} = live(conn, ~p"/it-support")
    view |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"}) |> render_submit()
    render_async(view, 20_000)
    render_async(view, 20_000)
    view
  end

  defp flush_stub do
    receive do
      {:stub_gemini, _, _} -> flush_stub()
    after
      0 -> :ok
    end
  end

  test "「もっと詳しく」 writes the answer again in detail, below the summary", %{conn: conn} do
    view = ask(conn)
    [_, id] = Regex.run(~r/id="summary-(\d+)"/, render(view))
    assert has_element?(view, "#restyle-#{id}-detailed")
    assert has_element?(view, "#restyle-#{id}-plain")

    flush_stub()
    StubGemini.set(:parts, [%{"text" => "USB メモリや外付け HDD など、外部記憶媒体の接続は禁止されています [1]。"}])
    view |> element("#restyle-#{id}-detailed") |> render_click()

    # the detailed style's instructions, without F-436's plan first
    assert_receive {:stub_gemini, call, body}, 5_000
    assert call =~ "streamGenerateContent"
    assert inspect(body) =~ "800字以内"

    render_async(view, 20_000)
    assert has_element?(view, "#restyled-#{id}-detailed", "外部記憶媒体の接続は禁止されています")
    # the desk's own answer stays, and each style is offered once
    assert has_element?(view, "#summary-#{id}", "接続は禁止です")
    refute has_element?(view, "#restyle-#{id}-detailed")
    assert has_element?(view, "#restyle-#{id}-plain")
  end

  test "the desk's own style is not offered again", %{conn: conn} do
    {:ok, _} = Settings.update_setting(Settings.get_setting!(), %{chat_answer_style: "plain"})
    view = ask(conn)
    [_, id] = Regex.run(~r/id="summary-(\d+)"/, render(view))
    assert has_element?(view, "#restyle-#{id}-detailed")
    refute has_element?(view, "#restyle-#{id}-plain")
  end

  test "not offered when the summary runs on a local model", %{conn: conn} do
    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{chat_summary_provider: "ollama"})

    {:ok, view, _html} = live(conn, ~p"/it-support")
    refute has_element?(view, "[id^='restyle-']")
  end
end
