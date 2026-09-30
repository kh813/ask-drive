defmodule AskDriveWeb.ChatLiveTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture())}
  end

  test "renders chat page and submits question", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/it-support")
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
    {:ok, view, _html} = live(conn, ~p"/it-support")

    view
    |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"})
    |> render_submit()

    html = render_async(view, 20_000)
    assert html =~ "USBメモリの利用ルールは？"
    assert html =~ "Unanswered" or html =~ "未回答"
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

    {:ok, view, _html} = live(conn, ~p"/it-support")

    view
    |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"})
    |> render_submit()

    html = render_async(view, 20_000)
    assert html =~ "Relevant excerpts" or html =~ "関連しそうな箇所"
    assert html =~ ~r{<mark[^>]*>USB メモリ</mark>}
    refute html =~ "じ じ"
    assert html =~ "p.33"
    assert html =~ "https://drive.google.com/file/d/abc/view?usp=drivesdk#page=33"
  end

  test "resets chat history", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/it-support")

    view
    |> form("#chat-form", %{"question" => "質問1"})
    |> render_submit()

    assert render(view) =~ "質問1"

    view
    |> element("#reset-chat-btn")
    |> render_click()

    refute render(view) =~ "質問1"
  end

  test "with login off (POC), visitors chat without signing in (as the guest)" do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)

    {:ok, view, _html} = live(build_conn(), ~p"/it-support")
    assert has_element?(view, "#chat-form")

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

    {:ok, view, _html} = live(conn, ~p"/it-support")

    view
    |> form("#chat-form", %{"question" => "USBメモリの利用ルールは？"})
    |> render_submit()

    render_async(view, 20_000)
    html = render_async(view, 20_000)

    assert html =~ "AI Summary" or html =~ "AI による要約"
    assert html =~ "外部記憶媒体の接続は禁止されています"
    assert html =~ ~r{<a href="#src-\d+-1"[^>]*>\[1\]</a>}
    assert html =~ ~r{id="src-\d+-1"}
  end

  test "a reasoning model's thinking is kept but collapsed, not mixed into the summary", %{
    conn: conn
  } do
    {server, url} = AskDrive.StubOllama.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    AskDrive.StubOllama.put_generate_pieces([
      "Okay, let's tackle this query.",
      "</think>",
      "持ち出しは許可制です [1]。"
    ])

    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        ollama_host: url,
        llm_provider: "ollama",
        embed_provider: "ollama",
        batch_model: "qwen3:4b"
      })

    {:ok, doc} =
      %AskDrive.Documents.Document{}
      |> AskDrive.Documents.Document.changeset(%{
        drive_file_id: "think_doc",
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
        content_hash: "t",
        content: "PCの持ち出しは事前申請による許可制とする。"
      })
      |> AskDrive.Repo.insert()

    {:ok, view, _html} = live(conn, ~p"/it-support")

    view
    |> form("#chat-form", %{"question" => "PCの持ち出しルールは？"})
    |> render_submit()

    render_async(view, 20_000)
    html = render_async(view, 20_000)

    assert html =~ "持ち出しは許可制です"
    assert html =~ "Show AI thinking process" or html =~ "AI の思考過程を表示"
    # the thinking sits inside a <details> (collapsed), after the answer
    assert html =~
             ~r{<details[^>]*>\s*<summary[^>]*>\s*(Show AI thinking process|AI の思考過程を表示).*Okay, let&#39;s tackle this query\.}s

    thinking_label =
      if html =~ "Show AI thinking process", do: "Show AI thinking process", else: "AI の思考過程を表示"

    [answer_part | _] = String.split(html, thinking_label)
    refute answer_part =~ "Okay, let"
  end

  describe "the app's passphrase (spec F-1112)" do
    alias AskDrive.Accounts.{AdminAccess, LoginThrottle}
    alias AskDrive.Settings

    setup do
      {:ok, _} = AdminAccess.set_access_password(Settings.get_setting!(), "pass12345")
      :ok
    end

    defp unlock(conn, password),
      do: post(conn, "/it-support/unlock", %{"chat_access" => %{"password" => password}})

    test "locked until the passphrase is given; the unlock holds across reloads", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/it-support")
      assert html =~ "chat-access-form"
      assert has_element?(view, ~s(#chat-access-form[action="/it-support/unlock"][method="post"]))

      # wrong: back to the app with a message, still locked
      bad = unlock(conn, "wrongpwd")
      assert redirected_to(bad) == "/it-support"
      assert Phoenix.Flash.get(bad.assigns.flash, :error) =~ "正しくありません"
      assert Phoenix.Flash.get(bad.assigns.flash, :error) =~ "あと 4 回"

      # right: remembered in the session, so this and later visits open the chat
      good = unlock(conn, "pass12345")
      assert redirected_to(good) == "/it-support"
      assert Phoenix.Flash.get(good.assigns.flash, :info) =~ "解除しました"

      conn = recycle(good)
      {:ok, view, html} = live(conn, ~p"/it-support")
      assert html =~ "chat-form"
      refute has_element?(view, "#chat-access-form")

      {:ok, _view, html} = live(recycle(conn), ~p"/it-support")
      assert html =~ "chat-form"
    end

    test "changing the passphrase invalidates earlier unlocks", %{conn: conn} do
      conn = conn |> unlock("pass12345") |> recycle()
      {:ok, _} = AdminAccess.set_access_password(Settings.get_setting!(), "new-pass-678")

      {:ok, view, html} = live(conn, ~p"/it-support")
      assert has_element?(view, "#chat-access-form")
      assert html =~ "chat-access-form"
    end

    test "5 wrong guesses within 5 minutes lock this browser out of the app, not everyone", %{
      conn: conn
    } do
      attacker =
        conn |> put_req_cookie("_askdrive_device", "x") |> Map.put(:remote_ip, {10, 0, 0, 9})

      for _ <- 1..5, do: unlock(attacker, "guess")

      locked = unlock(attacker, "pass12345")
      assert Phoenix.Flash.get(locked.assigns.flash, :error) =~ "まで受け付けません"
      refute get_session(locked, "unlocked_app_it-support")

      # another browser still gets in
      other = conn |> Map.put(:remote_ip, {10, 0, 0, 10}) |> unlock("pass12345")
      assert get_session(other, "unlocked_app_it-support")

      [lock | _] = LoginThrottle.active_locks()
      assert lock.key =~ "access:it-support|"
    end

    test "with login required, an anonymous visitor is sent to the login page" do
      conn = unlock(build_conn(), "pass12345")
      assert redirected_to(conn) =~ "/login"
    end
  end
end
