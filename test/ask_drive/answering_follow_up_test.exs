defmodule AskDrive.AnsweringFollowUpTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Answering

  test "a follow-up is searched together with the thread's earlier questions (F-431)" do
    result = Answering.ask("申請は何日前まで？", context: ["有給休暇は何日？"])
    assert result.question == "申請は何日前まで？"
    assert result.search_query == "有給休暇は何日？\n申請は何日前まで？"

    # a new question is searched as it is
    assert Answering.ask("有給休暇は何日？").search_query == "有給休暇は何日？"
  end

  test "the unanswered log keeps the follow-up with what it follows" do
    Answering.ask("申請は何日前まで？", context: ["有給休暇は何日？"])

    assert AskDrive.Repo.one(
             from q in AskDrive.QA.QuestionLog,
               order_by: [desc: q.id],
               limit: 1,
               select: q.question
           ) == "有給休暇は何日？ / 申請は何日前まで？"
  end
end
