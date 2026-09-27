defmodule AskDrive.QATest do
  use AskDrive.DataCase
  alias AskDrive.Documents.Document
  alias AskDrive.QA

  test "save_qa_pair_with_embedding inserts into qa_pairs and vec_qa_pairs" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "doc_qa_test_1",
        name: "就業規則.pdf",
        mime_type: "application/pdf"
      })
      |> Repo.insert()

    dummy_vec = for i <- 1..1024, do: if(i == 1, do: 1.0, else: 0.0)

    attrs = %{
      document_id: doc.id,
      question: "有給休暇の付与日数は？",
      answer: "初年度は10日付与されます。",
      source_hash: "hash_test",
      generated_by: "qwen3:4b"
    }

    {:ok, qa} = QA.save_qa_pair_with_embedding(attrs, dummy_vec)
    assert qa.id != nil
    assert qa.question == "有給休暇の付与日数は？"

    # Search in vec_qa_pairs
    results = QA.search_qa_vectors(dummy_vec, 2)
    assert length(results) >= 1
    assert {matched_qa, sim} = List.first(results)
    assert matched_qa.id == qa.id
    assert_in_delta sim, 1.0, 0.001
  end

  test "get_cached_answer and put_cached_answer manage Tier 0 cache" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "doc_cache_test",
        name: "規程.pdf",
        mime_type: "application/pdf"
      })
      |> Repo.insert()

    dummy_vec = for i <- 1..1024, do: if(i == 1, do: 1.0, else: 0.0)

    {:ok, qa} =
      QA.save_qa_pair_with_embedding(
        %{
          document_id: doc.id,
          question: "交通費の上限は？",
          answer: "月額3万円まで支給されます。",
          source_hash: "hash_koutsu",
          generated_by: "qwen3:4b"
        },
        dummy_vec
      )

    assert is_nil(QA.get_cached_answer("交通費の上限は？"))

    {:ok, _cache} = QA.put_cached_answer("交通費の上限は？", qa.id)

    cached_qa = QA.get_cached_answer("交通費の上限は？")
    assert cached_qa != nil
    assert cached_qa.id == qa.id
  end
end
