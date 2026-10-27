defmodule AskDrive.RetrievalExcerptsTest do
  @moduledoc """
  Tier 2's excerpts widen the best document's hits with the chunks next to them (F-434): a
  rule a few paragraphs from the part that matched reaches the summary.
  """
  use AskDrive.DataCase, async: true

  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.{ChatSummary, Retrieval, Settings}

  defp doc!(name, contents) do
    doc =
      %Document{}
      |> Document.changeset(%{drive_file_id: name, name: name, mime_type: "application/pdf"})
      |> Repo.insert!()

    chunks =
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

    {doc, chunks}
  end

  defp positions(excerpts), do: Enum.map(excerpts, fn {c, _} -> {c.document.name, c.position} end)

  test "the best document's hit gets its neighbours, in document order, before the others" do
    {_, rules} =
      doc!("命名規則.pdf", [
        "第1条 目的",
        "第2条 共有ドライブ名は「SEng_部署名」とする。",
        "第3条 名前に空白文字や記号は使わない。",
        "第4条 改定"
      ])

    {_, [other]} = doc!("FAQ.pdf", ["共有ドライブの作り方"])

    hits = [{Enum.at(rules, 1), 0.9}, {other, 0.5}]

    assert positions(Retrieval.with_neighbors(hits, 8)) == [
             {"命名規則.pdf", 0},
             {"命名規則.pdf", 1},
             {"命名規則.pdf", 2},
             {"FAQ.pdf", 0}
           ]
  end

  test "never more than the limit; other documents' hits keep two places" do
    {_, rules} = doc!("規則.pdf", for(i <- 0..9, do: "第#{i}条 規則の本文です。"))
    {_, a} = doc!("A.pdf", ["A の本文", "A の続き"])
    {_, b} = doc!("B.pdf", ["B の本文"])

    hits = [
      {Enum.at(rules, 4), 0.9},
      {Enum.at(rules, 7), 0.8},
      {hd(a), 0.5},
      {hd(b), 0.4},
      {Enum.at(a, 1), 0.3}
    ]

    excerpts = Retrieval.with_neighbors(hits, 6)
    assert length(excerpts) == 6
    # 2 hits + 2 neighbours of the best one (5 and 3); then two of the others
    assert positions(excerpts) == [
             {"規則.pdf", 3},
             {"規則.pdf", 4},
             {"規則.pdf", 5},
             {"規則.pdf", 7},
             {"A.pdf", 0},
             {"B.pdf", 0}
           ]
  end

  test "a neighbour already among the hits isn't repeated; nothing found stays nothing" do
    {_, rules} = doc!("規則.pdf", ["第1条", "第2条", "第3条"])
    hits = [{Enum.at(rules, 0), 0.9}, {Enum.at(rules, 1), 0.8}]

    assert positions(Retrieval.with_neighbors(hits, 8)) ==
             [{"規則.pdf", 0}, {"規則.pdf", 1}, {"規則.pdf", 2}]

    assert Retrieval.with_neighbors([], 8) == []
  end

  test "excerpts/3 searches and widens: the rule next to the matched part is found" do
    doc!("命名規則.pdf", [
      "共有ドライブの命名規則 第1条 共有ドライブ名は「SEng_部署名」の形式とする。",
      "第2条 名前に空白文字や記号は使わない（バックアップのスクリプトのため）。"
    ])

    excerpts = Retrieval.excerpts("共有ドライブの命名規則", nil, 8)
    assert Enum.any?(excerpts, fn {c, _} -> c.content =~ "空白文字" end)
  end

  test "up to 8 excerpts for a cloud summary, 4 on the local LLM, 3 without a summary" do
    setting = Settings.get_setting!()
    cloud = %{setting | chat_summary_enabled: true, chat_summary_provider: "gemini"}
    local = %{setting | chat_summary_enabled: true, chat_summary_provider: "ollama"}

    assert ChatSummary.excerpt_limit(cloud) == 8
    assert ChatSummary.excerpt_limit(local) == 4
    assert ChatSummary.excerpt_limit(%{cloud | chat_summary_enabled: false}) == 3
  end
end
