defmodule AskDrive.FreshnessTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Documents.{Chunk, DocSummary, Document, Extraction}
  alias AskDrive.Freshness
  alias AskDrive.QA.{AnswerCache, QAPair}
  alias AskDrive.Repo

  describe "Freshness tracking and invalidation" do
    setup do
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          drive_file_id: "doc_freshness_test",
          name: "旅費規程.docx",
          mime_type: "application/vnd.google-apps.document",
          status: "indexed",
          content_hash: "hash_v1"
        })
        |> Repo.insert()

      {:ok, chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          position: 0,
          heading: "第1条",
          content: "日当は1日あたり3000円を支給します。",
          content_hash: "chunk_v1_hash",
          token_estimate: 20
        })
        |> Repo.insert()

      {:ok, qa} =
        %QAPair{}
        |> QAPair.changeset(%{
          document_id: doc.id,
          chunk_id: chunk.id,
          question: "日当はいくら支給されますか？",
          answer: "1日あたり3000円が支給されます。",
          status: "active",
          source_hash: "chunk_v1_hash",
          generated_by: "qwen3:4b"
        })
        |> Repo.insert()

      {:ok, cache} =
        %AnswerCache{}
        |> AnswerCache.changeset(%{
          normalized_question: "日当はいくら支給されますか",
          qa_pair_id: qa.id,
          hit_count: 5
        })
        |> Repo.insert()

      {:ok, summary} =
        %DocSummary{}
        |> DocSummary.changeset(%{
          document_id: doc.id,
          summary: "旅費および日当に関する規定",
          status: "active",
          generated_by: "qwen3:4b"
        })
        |> Repo.insert()

      {:ok, extraction} =
        %Extraction{}
        |> Extraction.changeset(%{
          document_id: doc.id,
          chunk_id: chunk.id,
          key: "日当",
          value: "3000円",
          value_type: "money",
          status: "active"
        })
        |> Repo.insert()

      %{
        doc: doc,
        chunk: chunk,
        qa: qa,
        cache: cache,
        summary: summary,
        extraction: extraction
      }
    end

    test "invalidate_document/1 marks QAs, summaries, extractions as stale and evicts answer_cache",
         %{doc: doc, qa: qa, summary: summary, extraction: extraction} do
      Freshness.invalidate_document(doc)

      reloaded_qa = Repo.get!(QAPair, qa.id)
      assert reloaded_qa.status == "stale"

      reloaded_summary = Repo.get!(DocSummary, summary.id)
      assert reloaded_summary.status == "stale"

      reloaded_extraction = Repo.get!(Extraction, extraction.id)
      assert reloaded_extraction.status == "stale"

      # answer_cache must be evicted immediately
      assert Repo.all(from c in AnswerCache, where: c.qa_pair_id == ^qa.id) == []
    end

    test "delete_document_completely/1 purges document and all associated data", %{doc: doc} do
      Freshness.delete_document_completely(doc)

      assert Repo.get(Document, doc.id) == nil
      assert Repo.all(from c in Chunk, where: c.document_id == ^doc.id) == []
      assert Repo.all(from q in QAPair, where: q.document_id == ^doc.id) == []
      assert Repo.all(from s in DocSummary, where: s.document_id == ^doc.id) == []
    end
  end
end
