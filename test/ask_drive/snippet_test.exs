defmodule AskDrive.SnippetTest do
  use ExUnit.Case, async: true

  alias AskDrive.Ingest.TextCleaner
  alias AskDrive.Snippet

  describe "TextCleaner.clean/1" do
    test "drops side-tab and doubled-glyph debris from pdftotext -layout output" do
      raw = """
      じ じ
      は は
      プにより、重要データの漏えい・消失を防止します。
      これに                                                    第第
      部部
      第               リスクの大きな情報資産に対して必要とされる対策を決める
      部
      """

      assert TextCleaner.clean(raw) ==
               "プにより、重要データの漏えい・消失を防止します。\nこれに\nリスクの大きな情報資産に対して必要とされる対策を決める"
    end

    test "keeps table-like numbers and ordinary short content" do
      assert TextCleaner.clean("13:40             17:20") == "13:40 17:20"
      assert TextCleaner.clean("●可搬媒体の持込み・持出しを制限する") == "●可搬媒体の持込み・持出しを制限する"
    end

    test "is idempotent" do
      raw = "じ じ\n本文です。       第第\n"
      assert TextCleaner.clean(TextCleaner.clean(raw)) == TextCleaner.clean(raw)
    end
  end

  describe "Snippet.build/2" do
    test "highlights terms ignoring whitespace inside them and windows around the hits" do
      content =
        "[文書: guide.pdf]\n" <>
          String.duplicate("前置きの文章です。", 30) <>
          "\nウイルス感染の原因となるメールやウェブ閲覧に利用せず、USB メモリ、外付け HDD も接続を禁止する。"

      snippet = Snippet.build(content, "USBメモリの利用ルールは？")

      assert snippet.before?
      assert {:hit, "USB メモリ"} in snippet.segments
      assert {:hit, "利用"} in snippet.segments
      refute Enum.any?(snippet.segments, fn {_, t} -> String.contains?(t, "[文書:") end)
    end

    test "falls back to the start of the text when nothing matches" do
      snippet = Snippet.build("関係のない本文です。", "USBメモリ")
      assert snippet.hits == 0
      assert snippet.segments == [{:text, "関係のない本文です。"}]
    end
  end
end
