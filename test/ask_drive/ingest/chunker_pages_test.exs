defmodule AskDrive.Ingest.ChunkerPagesTest do
  use ExUnit.Case, async: true

  alias AskDrive.Ingest.Chunker

  test "stamps each chunk with the PDF page it starts on (form feed per page)" do
    text =
      "第1章 目的\n本規程は情報資産を守るための基本方針を定める。対象は全従業員とする。\n\f\n" <>
        "第2章 USB\nUSB メモリなどの外部記憶媒体は会社が貸与したもののみ利用できる。\n\f\n" <>
        "第3章 罰則\n違反した場合は就業規則に基づき処分する。"

    chunks =
      Chunker.chunk(text, doc_name: "規程.pdf", target_size: 40, max_size: 80, overlap_size: 0)

    usb = Enum.find(chunks, &String.contains?(&1.content, "USB メモリ"))
    penalty = Enum.find(chunks, &String.contains?(&1.content, "罰則"))

    assert usb.page == 2
    assert penalty.page == 3
    assert hd(chunks).page == 1
    refute Enum.any?(chunks, &String.contains?(&1.content, "\f"))
    refute Enum.any?(chunks, &Map.has_key?(&1, :body))
  end

  test "text without page breaks has no page" do
    [chunk | _] = Chunker.chunk("見出しのない本文です。十分な長さの文章をここに書きます。", doc_name: "a.txt")
    assert chunk.page == nil
  end
end
