defmodule AskDrive.Ingest.ChunkerTest do
  use ExUnit.Case, async: true
  alias AskDrive.Ingest.Chunker

  test "splits text by markdown headers and sentence boundaries" do
    text = """
    # 第一章 概要
    このシステムは完全ローカルで動作します。外部へのデータ送信は一切行いません。

    # 第二章 機能
    Google Driveからドキュメントを取得します。夜間に想定QAを事前生成します。
    """

    chunks = Chunker.chunk(text, doc_name: "仕様書.md", target_size: 100)
    assert length(chunks) >= 2

    first_chunk = List.first(chunks)
    assert first_chunk.heading == "第一章 概要"
    assert first_chunk.content =~ "[文書: 仕様書.md | セクション: 第一章 概要]"
    assert first_chunk.content =~ "完全ローカルで動作します"
    assert first_chunk.token_estimate > 0
    assert is_binary(first_chunk.content_hash)
  end

  test "handles mixed Japanese and English sentences with overlaps" do
    text = "AskDrive is a local chatbot. It runs on a Mac mini. 日本語の質問にも即座に回答します。"
    chunks = Chunker.chunk(text, doc_name: "README.md", target_size: 50, overlap_size: 20)

    assert length(chunks) >= 1
    assert Enum.all?(chunks, fn c -> String.length(c.content) >= 20 end)
  end

  test "forces split on extremely long sentences" do
    long_sentence = String.duplicate("あ", 1500)
    chunks = Chunker.chunk(long_sentence, target_size: 500, max_size: 800)

    assert length(chunks) >= 2
    assert Enum.all?(chunks, fn c -> String.length(c.content) <= 1000 end)
  end
end
