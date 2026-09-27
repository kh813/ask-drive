defmodule AskDrive.AnsweringTest do
  use AskDrive.DataCase
  alias AskDrive.Answering
  alias AskDrive.Documents.{Document, Chunk}
  alias AskDrive.QA.QuestionLog

  test "ask/1 returns tier 2 when relevant chunks exist and logs query" do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "doc_ans_1",
        name: "福利厚生.pdf",
        mime_type: "application/pdf"
      })
      |> Repo.insert()

    {:ok, _chunk} =
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        heading: "健康診断",
        content: "毎年10月に全社員を対象とした定期健康診断を実施します。",
        content_hash: "hash_kenkou"
      })
      |> Repo.insert()

    result = Answering.ask("健康診断の時期はいつですか？")
    assert result.tier in [2, 3]

    # Verify logged into question_log
    log = Repo.one(from q in QuestionLog, order_by: [desc: q.id], limit: 1)
    assert log != nil
    assert log.question == "健康診断の時期はいつですか？"
    assert log.tier_reached == result.tier
  end
end
