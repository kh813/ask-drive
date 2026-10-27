defmodule AskDrive.ChatSummaryReasonedTest do
  @moduledoc """
  On a cloud model, a question to think through (whether something follows the rules, or one
  whose aim lies behind its wording) is answered with whole documents and thinking; one the
  excerpts answer as they are is summarised as before (F-436).
  """
  use AskDrive.DataCase, async: false

  alias AskDrive.{ChatSummary, Settings, StubGemini}
  alias AskDrive.ChatSummary.Reasoned
  alias AskDrive.Documents.{Chunk, Document}

  defp doc!(name, contents) do
    doc =
      %Document{}
      |> Document.changeset(%{drive_file_id: name, name: name, mime_type: "application/pdf"})
      |> Repo.insert!()

    for {content, i} <- Enum.with_index(contents) do
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: i,
        content: content,
        content_hash: "#{name}#{i}"
      })
      |> Repo.insert!()
      |> Repo.preload(:document)
    end
  end

  defp naming_rules! do
    doc!("命名規則.pdf", [
      "共有ドライブの命名規則 第1条 共有ドライブ名は「SEng_部署名」の形式とする。",
      "第2条 目的: 名前で持ち主の部署が分かるようにする。",
      "第3条 名前に空白文字や記号は使わない。バックアップのスクリプトでエスケープ処理が要らないようにするため。"
    ])
  end

  defp gemini!(ctx \\ %{}) do
    {server, url} = StubGemini.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    {:ok, _} =
      Settings.update_setting(
        Settings.get_setting!(),
        Map.merge(
          %{
            chat_summary_provider: "gemini",
            chat_summary_model: "gemini-2.5-flash",
            gemini_api_key: "k",
            gemini_base_url: url
          },
          ctx
        )
      )

    :ok
  end

  defp plan!(mode, queries \\ []) do
    json = Jason.encode!(%{mode: mode, intent: "名前が規則に合うか知りたい", queries: queries})
    StubGemini.set(:generate_parts, [%{"text" => json}])
  end

  defp stream_body do
    assert_received {:stub_gemini, "gemini-2.5-flash:streamGenerateContent", body}
    body
  end

  defp prompt_of(body), do: body["contents"] |> hd() |> get_in(["parts", Access.at(0), "text"])

  describe "the plan" do
    test "reads the model's JSON, even fenced; anything else answers directly" do
      assert {:reasoned, "PDF を編集したい", ["PDF 編集", "許可アプリケーション"]} =
               Reasoned.parse_plan("""
               ```json
               {"mode": "reasoned", "intent": "PDF を編集したい", "queries": ["PDF 編集", "許可アプリケーション", "PDF 編集", ""]}
               ```
               """)

      assert Reasoned.parse_plan(~s({"mode": "direct", "intent": "", "queries": []})) == :direct
      assert Reasoned.parse_plan("たぶん reasoned です") == :direct
      assert Reasoned.parse_plan(~s({"mode": "reasoned"})) == {:reasoned, "", []}
    end

    test "shows the model the question and the start of each excerpt" do
      [first | _] = naming_rules!()
      prompt = Reasoned.plan_prompt("この名前は命名規則に沿っていますか？", [first])
      assert prompt =~ "この名前は命名規則に沿っていますか？"
      assert prompt =~ "[1] 命名規則.pdf: 共有ドライブの命名規則"
      assert prompt =~ ~s("reasoned")
      # an FAQ that has the question answers it directly, even a rule question
      assert prompt =~ "FAQ（よくある質問・Q&A）に、この質問に当たる質問と回答があれば"
    end
  end

  describe "what a reasoned answer is given" do
    test "the excerpts' whole documents, the excerpts keeping their numbers" do
      [first, second, third] = naming_rules!()
      sources = Reasoned.sources([second], [], Settings.get_setting!())

      # the excerpt is [1]; the rest of its document follows as [2], [3], in its order
      assert sources.count == 3
      assert sources.extra == [first, third]
      assert sources.text =~ "■ 命名規則.pdf"
      assert sources.text =~ "[2] 共有ドライブの命名規則"
      assert sources.text =~ "[1] 第2条"
      assert sources.text =~ "[3] 第3条 名前に空白文字や記号は使わない"
    end

    test "the plan's search words find other documents (the allowed apps list)" do
      [paid] = doc!("ソフトウェア利用規程.pdf", ["有償ソフトは、上長の承認を取ってから IT サポートに依頼する。"])
      doc!("許可アプリケーション一覧.pdf", ["PDF 編集: PDF-XChange Editor（無償）"])

      sources = Reasoned.sources([paid], ["PDF 編集"], Settings.get_setting!())
      assert sources.text =~ "■ 許可アプリケーション一覧.pdf"
      assert sources.text =~ "[2] PDF 編集: PDF-XChange Editor"
    end

    test "a document too long to give whole is given only the parts found" do
      long = String.duplicate("長い本文。", 4_500)
      [hit, _other] = doc!("長い規程.pdf", ["第1条 短い条文。", long])

      sources = Reasoned.sources([hit], [], Settings.get_setting!())
      assert sources.count == 1
      refute sources.text =~ "長い本文。"
    end

    test "the citations of the other parts are numbered after the excerpts, as cited" do
      [a, b, c] = naming_rules!()

      # [4] (b) is cited first → [2]; then [2] (a) → [3]; [3] (c) isn't cited, not shown
      assert Reasoned.renumber("沿っていません [1]。空白は使わない [4]。形式 [1, 2]。", 1, [a, c, b]) ==
               {"沿っていません [1]。空白は使わない [2]。形式 [1, 3]。", [b, a]}
    end
  end

  test "a rule question is thought through, with the whole document; the cited parts come back" do
    gemini!()
    [first, _second, third] = naming_rules!()
    plan!("reasoned")

    StubGemini.set(:parts, [
      %{"text" => "沿っていません [1]。名前に空白が含まれ、空白は使わない規則に反します [3]。"}
    ])

    question = "この共有ドライブ名は、命名規則に沿っていますか？ SEng_Electronic Stamp Keepers Restricted"

    assert {:ok, %{text: text, sources: [^third]}} = ChatSummary.generate(question, [first])
    assert text == "沿っていません [1]。名前に空白が含まれ、空白は使わない規則に反します [2]。"

    assert_received {:stub_gemini, "gemini-2.5-flash:generateContent", _plan}
    body = stream_body()
    # thinking on: no thinkingConfig, the model's own (dynamic) thinking
    refute get_in(body, ["generationConfig", "thinkingConfig"])
    assert get_in(body, ["systemInstruction", "parts", Access.at(0), "text"]) =~ "目的に照らして"

    prompt = prompt_of(body)
    assert prompt =~ "名前に空白文字や記号は使わない"
    assert prompt =~ "なぜその決まりがあるのか"
    assert prompt =~ "名前が規則に合うか知りたい"
    assert prompt =~ "FAQ（よくある質問・Q&A）に、この質問に当たる質問と回答があれば、その回答を基に"
  end

  test "a question the excerpts answer as they are is summarised as before" do
    gemini!()
    [usb] = doc!("情報セキュリティ規程.pdf", ["USB メモリの接続を禁止する。"])
    plan!("direct")
    StubGemini.set(:parts, [%{"text" => "USB メモリは使えません [1]。"}])

    assert {:ok, %{text: "USB メモリは使えません [1]。", sources: []}} =
             ChatSummary.generate("USBメモリを使っていいですか", [usb])

    body = stream_body()
    assert body["generationConfig"]["thinkingConfig"] == %{"thinkingBudget" => 0}
    assert prompt_of(body) =~ "抜粋に書かれている内容だけを使ってください"
  end

  test "on the local LLM there is no plan: summarised as before" do
    {server, url} = AskDrive.StubOllama.start!(self())
    on_exit(fn -> Process.exit(server, :normal) end)
    AskDrive.StubOllama.put_generate_pieces(["USB メモリは使えません [1]。"])

    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{
        ollama_host: url,
        llm_provider: "ollama",
        chat_summary_provider: "ollama",
        # not a reasoning model: one call
        chat_summary_model: "qwen3:4b-instruct-2507-q4_K_M"
      })

    [usb] = doc!("情報セキュリティ規程.pdf", ["USB メモリの接続を禁止する。"])

    assert {:ok, %{text: "USB メモリは使えません [1]。", sources: []}} =
             ChatSummary.generate("USBメモリを使っていいですか", [usb])

    assert_received {:stub_generate, body}
    refute body["prompt"] =~ "答え方を決めてください"
    refute_received {:stub_generate, _}
  end
end
