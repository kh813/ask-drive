defmodule AskDrive.AnsweringTiersTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Answering
  alias AskDrive.Documents.{Chunk, Document}
  alias AskDrive.QA.{AnswerCache, QAPair}
  alias AskDrive.Repo
  alias AskDrive.Settings

  describe "Tier 0/1/2/3 Answering routing and fallback" do
    setup do
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          drive_file_id: "doc_answering_test",
          name: "出張手当規定.docx",
          mime_type: "application/vnd.google-apps.document",
          status: "indexed",
          content_hash: "hash_出張"
        })
        |> Repo.insert()

      {:ok, chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          position: 0,
          heading: "第2条",
          content: "国内出張時の宿泊費の上限は1泊あたり12,000円（税込）とします。",
          content_hash: "chunk_hash_出張",
          token_estimate: 30
        })
        |> Repo.insert()

      {:ok, qa} =
        %QAPair{}
        |> QAPair.changeset(%{
          document_id: doc.id,
          chunk_id: chunk.id,
          question: "出張の宿泊費の上限はいくらですか？",
          answer: "国内出張の宿泊費上限は1泊12,000円（税込）です。",
          status: "active",
          source_hash: "chunk_hash_出張",
          generated_by: "qwen3:4b"
        })
        |> Repo.insert()

      %{doc: doc, chunk: chunk, qa: qa}
    end

    test "normalize_question/1 handles spaces, full-width characters and punctuation" do
      assert Answering.normalize_question("  出張の宿泊費の上限はいくらですか？？  ") ==
               "出張の宿泊費の上限はいくらですか"

      assert Answering.normalize_question("ＡＢＣ　１２３？") == "abc 123"
    end

    test "Tier 0 exact match responds instantly from answer_cache", %{qa: qa} do
      normalized = Answering.normalize_question("出張の宿泊費の上限はいくらですか？")

      # Put into answer_cache
      {:ok, _cache} =
        %AnswerCache{}
        |> AnswerCache.changeset(%{
          normalized_question: normalized,
          qa_pair_id: qa.id,
          hit_count: 1
        })
        |> Repo.insert()

      response = Answering.ask("出張の宿泊費の上限はいくらですか？")

      assert response.tier == 0
      assert response.answer == "国内出張の宿泊費上限は1泊12,000円（税込）です。"
      assert response.qa_pair.id == qa.id
    end

    test "stale QA is excluded from Tier 1 and falls back to Tier 2 when serve_stale_qa is false",
         %{qa: qa} do
      # Invalidate QA
      qa
      |> QAPair.changeset(%{status: "stale"})
      |> Repo.update!()

      setting = Settings.get_setting!()
      Settings.update_setting(setting, %{serve_stale_qa: false})

      response = Answering.ask("出張の宿泊費の上限はいくらですか？")

      # Should not hit Tier 0 or Tier 1 (falls back to Tier 2 excerpt or Tier 3)
      assert response.tier in [2, 3]
    end
  end

  describe "Tier 3 with nothing indexed" do
    test "flags index_empty? so the chat can say documents are not ingested yet" do
      response = Answering.ask("存在しない何かについての質問")
      assert response.tier == 3
      assert response.index_empty?
    end
  end

end
